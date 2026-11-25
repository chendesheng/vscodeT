// Port of `src/vs/platform/actions/common/actions.ts`.
//
// Terminal adaptations:
// - There is no global `Registry` singleton: `MenuRegistry` and
//   `ActionRegistries` are explicit instances owned by the host.
// - `MenuId` is a name-backed value (262 upstream ids are mirrored below) and
//   menus are keyed by that name.
// - `Action2` takes its run callback, keybinding and menu contribution as
//   fields. registerAction2 owns its action until the registration is disposed.
// - Title/tooltip localized strings are plain English strings.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../base/common/event.zig").Emitter;
const action = @import("../../action/common/action.zig");
const commands = @import("../../commands/common/commands.zig");
const keybindings_registry = @import("../../keybinding/common/keybindingsRegistry.zig");
const contextkey = @import("../../contextkey/common/contextkey.zig");

pub const ICommandAction = action.ICommandAction;

pub const MenuId = struct {
    id: []const u8,

    pub fn eql(a: MenuId, b: MenuId) bool {
        return std.mem.eql(u8, a.id, b.id);
    }
};

pub const menu_ids = struct {
    pub const CommandPalette = MenuId{ .id = "CommandPalette" };
    pub const DebugBreakpointsContext = MenuId{ .id = "DebugBreakpointsContext" };
    pub const DebugCallStackContext = MenuId{ .id = "DebugCallStackContext" };
    pub const DebugConsoleContext = MenuId{ .id = "DebugConsoleContext" };
    pub const DebugVariablesContext = MenuId{ .id = "DebugVariablesContext" };
    pub const NotebookVariablesContext = MenuId{ .id = "NotebookVariablesContext" };
    pub const DebugHoverContext = MenuId{ .id = "DebugHoverContext" };
    pub const DebugWatchContext = MenuId{ .id = "DebugWatchContext" };
    pub const DebugToolBar = MenuId{ .id = "DebugToolBar" };
    pub const DebugToolBarStop = MenuId{ .id = "DebugToolBarStop" };
    pub const DebugDisassemblyContext = MenuId{ .id = "DebugDisassemblyContext" };
    pub const DebugCallStackToolbar = MenuId{ .id = "DebugCallStackToolbar" };
    pub const DebugCreateConfiguration = MenuId{ .id = "DebugCreateConfiguration" };
    pub const DebugScopesContext = MenuId{ .id = "DebugScopesContext" };
    pub const EditorContext = MenuId{ .id = "EditorContext" };
    pub const SimpleEditorContext = MenuId{ .id = "SimpleEditorContext" };
    pub const EditorContent = MenuId{ .id = "EditorContent" };
    pub const EditorLineNumberContext = MenuId{ .id = "EditorLineNumberContext" };
    pub const EditorContextCopy = MenuId{ .id = "EditorContextCopy" };
    pub const EditorContextPeek = MenuId{ .id = "EditorContextPeek" };
    pub const EditorContextShare = MenuId{ .id = "EditorContextShare" };
    pub const EditorTitle = MenuId{ .id = "EditorTitle" };
    pub const EditorTitleLayout = MenuId{ .id = "EditorTitleLayout" };
    pub const ModalEditorTitle = MenuId{ .id = "ModalEditorTitle" };
    pub const ModalEditorTitleContext = MenuId{ .id = "ModalEditorTitleContext" };
    pub const ModalEditorEditorTitle = MenuId{ .id = "ModalEditorEditorTitle" };
    pub const CompactWindowEditorTitle = MenuId{ .id = "CompactWindowEditorTitle" };
    pub const EditorTitleRun = MenuId{ .id = "EditorTitleRun" };
    pub const EditorTitleContext = MenuId{ .id = "EditorTitleContext" };
    pub const EditorTitleContextShare = MenuId{ .id = "EditorTitleContextShare" };
    pub const EmptyEditorGroup = MenuId{ .id = "EmptyEditorGroup" };
    pub const EmptyEditorGroupContext = MenuId{ .id = "EmptyEditorGroupContext" };
    pub const EditorGroupWatermarkToolbar = MenuId{ .id = "EditorGroupWatermarkToolbar" };
    pub const EditorTabsBarContext = MenuId{ .id = "EditorTabsBarContext" };
    pub const EditorTabsBarShowTabsSubmenu = MenuId{ .id = "EditorTabsBarShowTabsSubmenu" };
    pub const EditorTabsBarShowTabsZenModeSubmenu = MenuId{ .id = "EditorTabsBarShowTabsZenModeSubmenu" };
    pub const EditorActionsPositionSubmenu = MenuId{ .id = "EditorActionsPositionSubmenu" };
    pub const DiffEditorViewSubmenu = MenuId{ .id = "DiffEditorViewSubmenu" };
    pub const EditorRenderWhitespaceSubmenu = MenuId{ .id = "EditorRenderWhitespaceSubmenu" };
    pub const EditorSplitMoveSubmenu = MenuId{ .id = "EditorSplitMoveSubmenu" };
    pub const ExplorerContext = MenuId{ .id = "ExplorerContext" };
    pub const ExplorerContextShare = MenuId{ .id = "ExplorerContextShare" };
    pub const ExtensionContext = MenuId{ .id = "ExtensionContext" };
    pub const ExtensionEditorContextMenu = MenuId{ .id = "ExtensionEditorContextMenu" };
    pub const GlobalActivity = MenuId{ .id = "GlobalActivity" };
    pub const CommandCenter = MenuId{ .id = "CommandCenter" };
    pub const CommandCenterCenter = MenuId{ .id = "CommandCenterCenter" };
    pub const LayoutControlMenuSubmenu = MenuId{ .id = "LayoutControlMenuSubmenu" };
    pub const LayoutControlMenu = MenuId{ .id = "LayoutControlMenu" };
    pub const MenubarMainMenu = MenuId{ .id = "MenubarMainMenu" };
    pub const MenubarAppearanceMenu = MenuId{ .id = "MenubarAppearanceMenu" };
    pub const MenubarDebugMenu = MenuId{ .id = "MenubarDebugMenu" };
    pub const MenubarEditMenu = MenuId{ .id = "MenubarEditMenu" };
    pub const MenubarCopy = MenuId{ .id = "MenubarCopy" };
    pub const MenubarFileMenu = MenuId{ .id = "MenubarFileMenu" };
    pub const MenubarGoMenu = MenuId{ .id = "MenubarGoMenu" };
    pub const MenubarHelpMenu = MenuId{ .id = "MenubarHelpMenu" };
    pub const MenubarLayoutMenu = MenuId{ .id = "MenubarLayoutMenu" };
    pub const MenubarNewBreakpointMenu = MenuId{ .id = "MenubarNewBreakpointMenu" };
    pub const PanelAlignmentMenu = MenuId{ .id = "PanelAlignmentMenu" };
    pub const PanelPositionMenu = MenuId{ .id = "PanelPositionMenu" };
    pub const ActivityBarPositionMenu = MenuId{ .id = "ActivityBarPositionMenu" };
    pub const NotificationsCenterPositionMenu = MenuId{ .id = "NotificationsCenterPositionMenu" };
    pub const MenubarPreferencesMenu = MenuId{ .id = "MenubarPreferencesMenu" };
    pub const MenubarRecentMenu = MenuId{ .id = "MenubarRecentMenu" };
    pub const MenubarSelectionMenu = MenuId{ .id = "MenubarSelectionMenu" };
    pub const MenubarShare = MenuId{ .id = "MenubarShare" };
    pub const MenubarSwitchEditorMenu = MenuId{ .id = "MenubarSwitchEditorMenu" };
    pub const MenubarSwitchGroupMenu = MenuId{ .id = "MenubarSwitchGroupMenu" };
    pub const MenubarTerminalMenu = MenuId{ .id = "MenubarTerminalMenu" };
    pub const MenubarTerminalSuggestStatusMenu = MenuId{ .id = "MenubarTerminalSuggestStatusMenu" };
    pub const MenubarViewMenu = MenuId{ .id = "MenubarViewMenu" };
    pub const MenubarHomeMenu = MenuId{ .id = "MenubarHomeMenu" };
    pub const OpenEditorsContext = MenuId{ .id = "OpenEditorsContext" };
    pub const OpenEditorsContextShare = MenuId{ .id = "OpenEditorsContextShare" };
    pub const ProblemsPanelContext = MenuId{ .id = "ProblemsPanelContext" };
    pub const SCMInputBox = MenuId{ .id = "SCMInputBox" };
    pub const SCMChangeContext = MenuId{ .id = "SCMChangeContext" };
    pub const SCMResourceContext = MenuId{ .id = "SCMResourceContext" };
    pub const SCMResourceContextShare = MenuId{ .id = "SCMResourceContextShare" };
    pub const SCMResourceFolderContext = MenuId{ .id = "SCMResourceFolderContext" };
    pub const SCMResourceGroupContext = MenuId{ .id = "SCMResourceGroupContext" };
    pub const SCMSourceControl = MenuId{ .id = "SCMSourceControl" };
    pub const SCMSourceControlInline = MenuId{ .id = "SCMSourceControlInline" };
    pub const SCMSourceControlTitle = MenuId{ .id = "SCMSourceControlTitle" };
    pub const SCMHistoryTitle = MenuId{ .id = "SCMHistoryTitle" };
    pub const SCMHistoryItemContext = MenuId{ .id = "SCMHistoryItemContext" };
    pub const SCMHistoryItemChangeContext = MenuId{ .id = "SCMHistoryItemChangeContext" };
    pub const SCMHistoryItemRefContext = MenuId{ .id = "SCMHistoryItemRefContext" };
    pub const SCMArtifactGroupContext = MenuId{ .id = "SCMArtifactGroupContext" };
    pub const SCMArtifactContext = MenuId{ .id = "SCMArtifactContext" };
    pub const SCMQuickDiffDecorations = MenuId{ .id = "SCMQuickDiffDecorations" };
    pub const SCMTitle = MenuId{ .id = "SCMTitle" };
    pub const SearchContext = MenuId{ .id = "SearchContext" };
    pub const SearchActionMenu = MenuId{ .id = "SearchActionContext" };
    pub const StatusBarWindowIndicatorMenu = MenuId{ .id = "StatusBarWindowIndicatorMenu" };
    pub const StatusBarRemoteIndicatorMenu = MenuId{ .id = "StatusBarRemoteIndicatorMenu" };
    pub const StickyScrollContext = MenuId{ .id = "StickyScrollContext" };
    pub const TestItem = MenuId{ .id = "TestItem" };
    pub const TestItemGutter = MenuId{ .id = "TestItemGutter" };
    pub const TestProfilesContext = MenuId{ .id = "TestProfilesContext" };
    pub const TestMessageContext = MenuId{ .id = "TestMessageContext" };
    pub const TestMessageContent = MenuId{ .id = "TestMessageContent" };
    pub const TestPeekElement = MenuId{ .id = "TestPeekElement" };
    pub const TestPeekTitle = MenuId{ .id = "TestPeekTitle" };
    pub const TestCallStack = MenuId{ .id = "TestCallStack" };
    pub const TestCoverageFilterItem = MenuId{ .id = "TestCoverageFilterItem" };
    pub const TouchBarContext = MenuId{ .id = "TouchBarContext" };
    pub const TitleBar = MenuId{ .id = "TitleBar" };
    pub const TitleBarAdjacentCenter = MenuId{ .id = "TitleBarAdjacentCenter" };
    pub const TitleBarUpdate = MenuId{ .id = "TitleBarUpdate" };
    pub const TitleBarContext = MenuId{ .id = "TitleBarContext" };
    pub const TitleBarTitleContext = MenuId{ .id = "TitleBarTitleContext" };
    pub const TunnelContext = MenuId{ .id = "TunnelContext" };
    pub const TunnelPrivacy = MenuId{ .id = "TunnelPrivacy" };
    pub const TunnelProtocol = MenuId{ .id = "TunnelProtocol" };
    pub const TunnelPortInline = MenuId{ .id = "TunnelInline" };
    pub const TunnelTitle = MenuId{ .id = "TunnelTitle" };
    pub const TunnelLocalAddressInline = MenuId{ .id = "TunnelLocalAddressInline" };
    pub const TunnelOriginInline = MenuId{ .id = "TunnelOriginInline" };
    pub const ViewItemContext = MenuId{ .id = "ViewItemContext" };
    pub const ViewContainerTitle = MenuId{ .id = "ViewContainerTitle" };
    pub const ViewContainerTitleContext = MenuId{ .id = "ViewContainerTitleContext" };
    pub const ViewTitle = MenuId{ .id = "ViewTitle" };
    pub const ViewTitleContext = MenuId{ .id = "ViewTitleContext" };
    pub const CommentEditorActions = MenuId{ .id = "CommentEditorActions" };
    pub const CommentThreadTitle = MenuId{ .id = "CommentThreadTitle" };
    pub const CommentThreadActions = MenuId{ .id = "CommentThreadActions" };
    pub const CommentThreadAdditionalActions = MenuId{ .id = "CommentThreadAdditionalActions" };
    pub const CommentThreadTitleContext = MenuId{ .id = "CommentThreadTitleContext" };
    pub const CommentThreadCommentContext = MenuId{ .id = "CommentThreadCommentContext" };
    pub const CommentTitle = MenuId{ .id = "CommentTitle" };
    pub const CommentActions = MenuId{ .id = "CommentActions" };
    pub const CommentsViewThreadActions = MenuId{ .id = "CommentsViewThreadActions" };
    pub const InteractiveToolbar = MenuId{ .id = "InteractiveToolbar" };
    pub const InteractiveCellTitle = MenuId{ .id = "InteractiveCellTitle" };
    pub const InteractiveCellDelete = MenuId{ .id = "InteractiveCellDelete" };
    pub const InteractiveCellExecute = MenuId{ .id = "InteractiveCellExecute" };
    pub const InteractiveInputExecute = MenuId{ .id = "InteractiveInputExecute" };
    pub const InteractiveInputConfig = MenuId{ .id = "InteractiveInputConfig" };
    pub const ReplInputExecute = MenuId{ .id = "ReplInputExecute" };
    pub const IssueReporter = MenuId{ .id = "IssueReporter" };
    pub const NotebookToolbar = MenuId{ .id = "NotebookToolbar" };
    pub const NotebookToolbarContext = MenuId{ .id = "NotebookToolbarContext" };
    pub const NotebookStickyScrollContext = MenuId{ .id = "NotebookStickyScrollContext" };
    pub const NotebookCellTitle = MenuId{ .id = "NotebookCellTitle" };
    pub const NotebookCellDelete = MenuId{ .id = "NotebookCellDelete" };
    pub const NotebookCellInsert = MenuId{ .id = "NotebookCellInsert" };
    pub const NotebookCellBetween = MenuId{ .id = "NotebookCellBetween" };
    pub const NotebookCellListTop = MenuId{ .id = "NotebookCellTop" };
    pub const NotebookCellExecute = MenuId{ .id = "NotebookCellExecute" };
    pub const NotebookCellExecuteGoTo = MenuId{ .id = "NotebookCellExecuteGoTo" };
    pub const NotebookCellExecutePrimary = MenuId{ .id = "NotebookCellExecutePrimary" };
    pub const NotebookDiffCellInputTitle = MenuId{ .id = "NotebookDiffCellInputTitle" };
    pub const NotebookDiffDocumentMetadata = MenuId{ .id = "NotebookDiffDocumentMetadata" };
    pub const NotebookDiffCellMetadataTitle = MenuId{ .id = "NotebookDiffCellMetadataTitle" };
    pub const NotebookDiffCellOutputsTitle = MenuId{ .id = "NotebookDiffCellOutputsTitle" };
    pub const NotebookOutputToolbar = MenuId{ .id = "NotebookOutputToolbar" };
    pub const NotebookOutlineFilter = MenuId{ .id = "NotebookOutlineFilter" };
    pub const NotebookOutlineActionMenu = MenuId{ .id = "NotebookOutlineActionMenu" };
    pub const NotebookEditorLayoutConfigure = MenuId{ .id = "NotebookEditorLayoutConfigure" };
    pub const NotebookKernelSource = MenuId{ .id = "NotebookKernelSource" };
    pub const BulkEditTitle = MenuId{ .id = "BulkEditTitle" };
    pub const BulkEditContext = MenuId{ .id = "BulkEditContext" };
    pub const TimelineItemContext = MenuId{ .id = "TimelineItemContext" };
    pub const TimelineTitle = MenuId{ .id = "TimelineTitle" };
    pub const TimelineTitleContext = MenuId{ .id = "TimelineTitleContext" };
    pub const TimelineFilterSubMenu = MenuId{ .id = "TimelineFilterSubMenu" };
    pub const AccountsContext = MenuId{ .id = "AccountsContext" };
    pub const SidebarTitle = MenuId{ .id = "SidebarTitle" };
    pub const PanelTitle = MenuId{ .id = "PanelTitle" };
    pub const AuxiliaryBarTitle = MenuId{ .id = "AuxiliaryBarTitle" };
    pub const TerminalInstanceContext = MenuId{ .id = "TerminalInstanceContext" };
    pub const TerminalEditorInstanceContext = MenuId{ .id = "TerminalEditorInstanceContext" };
    pub const TerminalNewDropdownContext = MenuId{ .id = "TerminalNewDropdownContext" };
    pub const TerminalTabContext = MenuId{ .id = "TerminalTabContext" };
    pub const TerminalTabEmptyAreaContext = MenuId{ .id = "TerminalTabEmptyAreaContext" };
    pub const TerminalStickyScrollContext = MenuId{ .id = "TerminalStickyScrollContext" };
    pub const WebviewContext = MenuId{ .id = "WebviewContext" };
    pub const InlineCompletionsActions = MenuId{ .id = "InlineCompletionsActions" };
    pub const InlineEditsActions = MenuId{ .id = "InlineEditsActions" };
    pub const NewFile = MenuId{ .id = "NewFile" };
    pub const MergeInput1Toolbar = MenuId{ .id = "MergeToolbar1Toolbar" };
    pub const MergeInput2Toolbar = MenuId{ .id = "MergeToolbar2Toolbar" };
    pub const MergeBaseToolbar = MenuId{ .id = "MergeBaseToolbar" };
    pub const MergeInputResultToolbar = MenuId{ .id = "MergeToolbarResultToolbar" };
    pub const InlineSuggestionToolbar = MenuId{ .id = "InlineSuggestionToolbar" };
    pub const InlineEditToolbar = MenuId{ .id = "InlineEditToolbar" };
    pub const ChatContext = MenuId{ .id = "ChatContext" };
    pub const ChatCodeBlock = MenuId{ .id = "ChatCodeblock" };
    pub const ChatCompareBlock = MenuId{ .id = "ChatCompareBlock" };
    pub const ChatMessageTitle = MenuId{ .id = "ChatMessageTitle" };
    pub const ChatWelcomeContext = MenuId{ .id = "ChatWelcomeContext" };
    pub const ChatMessageFooter = MenuId{ .id = "ChatMessageFooter" };
    pub const ChatSubagentContent = MenuId{ .id = "ChatSubagentContent" };
    pub const ChatExecute = MenuId{ .id = "ChatExecute" };
    pub const ChatExecuteQueue = MenuId{ .id = "ChatExecuteQueue" };
    pub const ChatInput = MenuId{ .id = "ChatInput" };
    pub const ChatInputSecondary = MenuId{ .id = "ChatInputSecondary" };
    pub const ChatInputStatus = MenuId{ .id = "ChatInputStatus" };
    pub const ChatInputSide = MenuId{ .id = "ChatInputSide" };
    pub const AutomationsDialogInput = MenuId{ .id = "AutomationsDialogInput" };
    pub const ChatModePicker = MenuId{ .id = "ChatModePicker" };
    pub const ChatEditingWidgetToolbar = MenuId{ .id = "ChatEditingWidgetToolbar" };
    pub const ChatEditingSessionChangesToolbar = MenuId{ .id = "ChatEditingSessionChangesToolbar" };
    pub const ChatEditingSessionTitleToolbar = MenuId{ .id = "ChatEditingSessionTitleToolbar" };
    pub const ChatEditingSessionChangesVersionsSubmenu = MenuId{ .id = "ChatEditingSessionChangesVersionsSubmenu" };
    pub const ChatEditingSessionChangesFileHeaderToolbar = MenuId{ .id = "ChatEditingSessionChangesFileHeaderToolbar" };
    pub const ChatEditingSessionChangesFileHeaderRightToolbar = MenuId{ .id = "ChatEditingSessionChangesFileHeaderRightToolbar" };
    pub const ChatEditingEditorContent = MenuId{ .id = "ChatEditingEditorContent" };
    pub const ChatEditingEditorHunk = MenuId{ .id = "ChatEditingEditorHunk" };
    pub const ChatEditingDeletedNotebookCell = MenuId{ .id = "ChatEditingDeletedNotebookCell" };
    pub const ChatInputAttachmentToolbar = MenuId{ .id = "ChatInputAttachmentToolbar" };
    pub const ChatEditingWidgetModifiedFilesToolbar = MenuId{ .id = "ChatEditingWidgetModifiedFilesToolbar" };
    pub const ChatInputResourceAttachmentContext = MenuId{ .id = "ChatInputResourceAttachmentContext" };
    pub const ChatImageContext = MenuId{ .id = "ChatImageContext" };
    pub const ChatInputSymbolAttachmentContext = MenuId{ .id = "ChatInputSymbolAttachmentContext" };
    pub const ChatInlineResourceAnchorContext = MenuId{ .id = "ChatInlineResourceAnchorContext" };
    pub const ChatInlineSymbolAnchorContext = MenuId{ .id = "ChatInlineSymbolAnchorContext" };
    pub const ChatNewMenu = MenuId{ .id = "ChatNewMenu" };
    pub const ChatEditingCodeBlockContext = MenuId{ .id = "ChatEditingCodeBlockContext" };
    pub const ChatTitleBarMenu = MenuId{ .id = "ChatTitleBarMenu" };
    pub const ChatViewMode = MenuId{ .id = "ChatViewMode" };
    pub const ChatAttachmentsContext = MenuId{ .id = "ChatAttachmentsContext" };
    pub const ChatTipContext = MenuId{ .id = "ChatTipContext" };
    pub const ChatTipToolbar = MenuId{ .id = "ChatTipToolbar" };
    pub const ChatToolOutputResourceToolbar = MenuId{ .id = "ChatToolOutputResourceToolbar" };
    pub const ChatTextEditorMenu = MenuId{ .id = "ChatTextEditorMenu" };
    pub const ChatToolOutputResourceContext = MenuId{ .id = "ChatToolOutputResourceContext" };
    pub const ChatMultiDiffContext = MenuId{ .id = "ChatMultiDiffContext" };
    pub const ChatConfirmationMenu = MenuId{ .id = "ChatConfirmationMenu" };
    pub const ChatEditorInlineMenu = MenuId{ .id = "ChatEditorInlineGutter" };
    pub const ChatEditorInlineExecute = MenuId{ .id = "ChatEditorInputExecute" };
    pub const ChatEditorInlineInputSide = MenuId{ .id = "ChatEditorInputSide" };
    pub const InlineChatEditorAffordance = MenuId{ .id = "InlineChatEditorAffordance" };
    pub const AccessibleView = MenuId{ .id = "AccessibleView" };
    pub const MultiDiffEditorContent = MenuId{ .id = "MultiDiffEditorContent" };
    pub const MultiDiffEditorFileToolbar = MenuId{ .id = "MultiDiffEditorFileToolbar" };
    pub const DiffEditorHunkToolbar = MenuId{ .id = "DiffEditorHunkToolbar" };
    pub const DiffEditorSelectionToolbar = MenuId{ .id = "DiffEditorSelectionToolbar" };
    pub const BrowserNavigationToolbar = MenuId{ .id = "BrowserNavigationToolbar" };
    pub const BrowserActionsToolbar = MenuId{ .id = "BrowserActionsToolbar" };
    pub const BrowserChatActionsMenu = MenuId{ .id = "BrowserChatActionsMenu" };
    pub const BrowserEmulationToolbar = MenuId{ .id = "BrowserEmulationToolbar" };
    pub const AgentSessionsViewerFilterSubMenu = MenuId{ .id = "AgentSessionsViewerFilterSubMenu" };
    pub const AgentSessionsExternalFilterSubMenu = MenuId{ .id = "AgentSessionsExternalFilterSubMenu" };
    pub const AgentSessionsContext = MenuId{ .id = "AgentSessionsContext" };
    pub const AgentSessionSectionContext = MenuId{ .id = "AgentSessionSectionContext" };
    pub const AgentSessionsCreateSubMenu = MenuId{ .id = "AgentSessionsCreateSubMenu" };
    pub const AgentSessionsToolbar = MenuId{ .id = "AgentSessionsToolbar" };
    pub const AgentSessionItemToolbar = MenuId{ .id = "AgentSessionItemToolbar" };
    pub const AgentSessionSectionToolbar = MenuId{ .id = "AgentSessionSectionToolbar" };
    pub const SessionItemContextMenu = MenuId{ .id = "SessionItemContextMenu" };
    pub const SessionHeaderContext = MenuId{ .id = "SessionsSessionHeaderContext" };
    pub const AgentsTitleBarControlMenu = MenuId{ .id = "AgentsTitleBarControlMenu" };
    pub const AgentsChangesToolbar = MenuId{ .id = "AgentsChangesToolbar" };
    pub const AgentsChangesPrimaryActionSubMenu = MenuId{ .id = "AgentsChangesPrimaryActionSubMenu" };
    pub const AgentsChangeInlineToolbar = MenuId{ .id = "AgentsChangeInlineToolbar" };
    pub const ChatViewSessionTitleNavigationToolbar = MenuId{ .id = "ChatViewSessionTitleNavigationToolbar" };
    pub const ChatViewSessionTitleToolbar = MenuId{ .id = "ChatViewSessionTitleToolbar" };
    pub const ChatContextUsageActions = MenuId{ .id = "ChatContextUsageActions" };
    pub const MarkerHoverStatusBar = MenuId{ .id = "MarkerHoverParticipant.StatusBar" };
};

pub const IMenuItem = struct {
    command: ICommandAction,
    /// Alternative command for this menu item.
    alt: ?ICommandAction = null,
    /// Item is hidden when this expression returns false.
    when: ?*const contextkey.Expr = null,
    group: []const u8 = "",
    order: i64 = 0,
    is_hidden_by_default: bool = false,
};

pub const ISubmenuItem = struct {
    title: []const u8,
    submenu: MenuId,
    icon: ?action.Icon = null,
    when: ?*const contextkey.Expr = null,
    /// Submenu is checked when this expression returns true.
    toggled: ?*const contextkey.Expr = null,
    group: []const u8 = "",
    order: i64 = 0,
    is_selection: bool = false,
};

pub const MenuEntry = union(enum) {
    command: IMenuItem,
    submenu: ISubmenuItem,
};

pub fn isIMenuItem(entry: MenuEntry) bool {
    return entry == .command;
}

pub fn isISubmenuItem(entry: MenuEntry) bool {
    return entry == .submenu;
}

pub const MenuChangeEvent = struct {
    menu: MenuId,
};

/// Upstream `MenuRegistry`.
pub const MenuRegistry = struct {
    allocator: Allocator,
    menus: std.StringHashMap(std.array_list.Managed(MenuEntry)),
    groups: std.StringHashMap(std.StringHashMap(std.array_list.Managed([]const u8))),
    commands: std.StringHashMap(ICommandAction),
    implicit_items: std.array_list.Managed(MenuEntry),
    get_menu_items_calls: std.StringHashMap(usize),
    on_did_change: Emitter(MenuChangeEvent),

    pub fn init(allocator: Allocator) MenuRegistry {
        return .{
            .allocator = allocator,
            .menus = std.StringHashMap(std.array_list.Managed(MenuEntry)).init(allocator),
            .groups = std.StringHashMap(std.StringHashMap(std.array_list.Managed([]const u8))).init(allocator),
            .commands = std.StringHashMap(ICommandAction).init(allocator),
            .implicit_items = std.array_list.Managed(MenuEntry).init(allocator),
            .get_menu_items_calls = std.StringHashMap(usize).init(allocator),
            .on_did_change = Emitter(MenuChangeEvent).init(allocator),
        };
    }

    pub fn deinit(self: *MenuRegistry) void {
        var iterator = self.menus.valueIterator();
        while (iterator.next()) |list| list.deinit();
        self.menus.deinit();
        var group_iterator = self.groups.valueIterator();
        while (group_iterator.next()) |map| {
            var titles = map.valueIterator();
            while (titles.next()) |list| list.deinit();
            map.deinit();
        }
        self.groups.deinit();
        self.commands.deinit();
        self.implicit_items.deinit();
        self.get_menu_items_calls.deinit();
        self.on_did_change.deinit();
    }

    /// Describes the title of a menu group; contributors only add items to it.
    pub fn appendMenuGroup(self: *MenuRegistry, id: MenuId, group: []const u8, title: []const u8) !void {
        _ = try self.appendMenuGroupTracked(id, group, title);
    }

    pub fn appendMenuGroupTracked(self: *MenuRegistry, id: MenuId, group: []const u8, title: []const u8) !Registration {
        const entry = try self.groups.getOrPut(id.id);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.StringHashMap(std.array_list.Managed([]const u8)).init(self.allocator);
        }
        const list = try entry.value_ptr.getOrPut(group);
        if (!list.found_existing) list.value_ptr.* = std.array_list.Managed([]const u8).init(self.allocator);
        try list.value_ptr.append(title);
        try self.on_did_change.fire(.{ .menu = id });
        return .{ .registry = self, .menu = id, .group = group, .group_title = title };
    }

    /// Mutable view of the newest command item for the id (test/authoring seam;
    /// upstream callers mutate the JS `IMenuItem` object directly).
    pub fn getMenuItemPtr(self: *MenuRegistry, id: MenuId, command_id: []const u8) ?*IMenuItem {
        const list = self.menus.getPtr(id.id) orelse return null;
        var index = list.items.len;
        while (index > 0) {
            index -= 1;
            switch (list.items[index]) {
                .command => |*item| {
                    if (std.mem.eql(u8, item.command.id, command_id)) return item;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn getMenuItemsCallCount(self: *MenuRegistry, id: MenuId) usize {
        return self.get_menu_items_calls.get(id.id) orelse 0;
    }

    pub fn getMenuGroupTitle(self: *MenuRegistry, id: MenuId, group: []const u8) ?[]const u8 {
        const groups = self.groups.getPtr(id.id) orelse return null;
        const list = groups.getPtr(group) orelse return null;
        if (list.items.len == 0) return null;
        return list.items[list.items.len - 1];
    }

    fn menuList(self: *MenuRegistry, id: MenuId) !*std.array_list.Managed(MenuEntry) {
        const entry = try self.menus.getOrPut(id.id);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.array_list.Managed(MenuEntry).init(self.allocator);
        }
        return entry.value_ptr;
    }

    pub fn appendMenuItem(self: *MenuRegistry, id: MenuId, item: IMenuItem) !void {
        const list = try self.menuList(id);
        try list.append(.{ .command = item });
        try self.on_did_change.fire(.{ .menu = id });
    }

    pub const Registration = struct {
        registry: *MenuRegistry,
        menu: MenuId,
        command_id: ?[]const u8 = null,
        submenu: ?MenuId = null,
        when: ?*const contextkey.Expr = null,
        group: ?[]const u8 = null,
        group_title: ?[]const u8 = null,
        implicit_command: bool = false,

        pub fn dispose(self: Registration) void {
            if (self.group) |group| {
                self.registry.removeMenuGroup(self.menu, group, self.group_title orelse return);
                return;
            }
            if (self.implicit_command) {
                self.registry.removeCommand(self.command_id.?);
                return;
            }
            self.registry.removeRegistration(self);
        }
    };

    pub fn appendMenuItemTracked(self: *MenuRegistry, id: MenuId, item: IMenuItem) !Registration {
        try self.appendMenuItem(id, item);
        return .{ .registry = self, .menu = id, .command_id = item.command.id, .when = item.when };
    }

    pub fn appendSubmenuItemTracked(self: *MenuRegistry, id: MenuId, item: ISubmenuItem) !Registration {
        try self.appendSubmenuItem(id, item);
        return .{ .registry = self, .menu = id, .submenu = item.submenu, .when = item.when };
    }

    fn removeMenuGroup(self: *MenuRegistry, id: MenuId, group: []const u8, title: []const u8) void {
        const groups = self.groups.getPtr(id.id) orelse return;
        const list = groups.getPtr(group) orelse return;
        var index = list.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, list.items[index], title)) {
                _ = list.orderedRemove(index);
                break;
            }
        }
        self.on_did_change.fire(.{ .menu = id }) catch {};
    }

    fn removeRegistration(self: *MenuRegistry, registration: Registration) void {
        const list = self.menus.getPtr(registration.menu.id) orelse return;
        var index = list.items.len;
        while (index > 0) {
            index -= 1;
            const matches = if (registration.command_id) |command_id| switch (list.items[index]) {
                .command => |item| std.mem.eql(u8, item.command.id, command_id) and item.when == registration.when,
                else => false,
            } else if (registration.submenu) |submenu| switch (list.items[index]) {
                .submenu => |item| MenuId.eql(item.submenu, submenu) and item.when == registration.when,
                else => false,
            } else false;
            if (matches) {
                _ = list.orderedRemove(index);
                break;
            }
        }
        self.on_did_change.fire(.{ .menu = registration.menu }) catch {};
    }

    pub fn appendSubmenuItem(self: *MenuRegistry, id: MenuId, item: ISubmenuItem) !void {
        const list = try self.menuList(id);
        try list.append(.{ .submenu = item });
        try self.on_did_change.fire(.{ .menu = id });
    }

    /// Registers a command for implicit command-palette visibility.
    pub fn addCommand(self: *MenuRegistry, command: ICommandAction) !void {
        try self.commands.put(command.id, command);
        try self.on_did_change.fire(.{ .menu = menu_ids.CommandPalette });
    }

    pub fn addCommandTracked(self: *MenuRegistry, command: ICommandAction) !Registration {
        try self.addCommand(command);
        return .{ .registry = self, .menu = menu_ids.CommandPalette, .command_id = command.id, .implicit_command = true };
    }

    pub fn removeCommand(self: *MenuRegistry, id: []const u8) void {
        _ = self.commands.remove(id);
        self.on_did_change.fire(.{ .menu = menu_ids.CommandPalette }) catch {};
    }

    pub fn getCommand(self: *MenuRegistry, id: []const u8) ?ICommandAction {
        return self.commands.get(id);
    }

    /// Items are returned in insertion order; the menu service applies
    /// visibility and ordering. The command palette additionally shows every
    /// registered command that has no explicit palette item (upstream
    /// `_appendImplicitItems`). That slice is owned by the registry scratch
    /// buffer and is invalidated by the next palette lookup.
    pub fn getMenuItems(self: *MenuRegistry, id: MenuId) []const MenuEntry {
        const counter = self.get_menu_items_calls.getOrPut(id.id) catch return &.{};
        if (!counter.found_existing) counter.value_ptr.* = 0;
        counter.value_ptr.* += 1;
        const list = self.menus.getPtr(id.id);
        if (!MenuId.eql(id, menu_ids.CommandPalette)) {
            return if (list) |entries| entries.items else &.{};
        }

        self.implicit_items.clearRetainingCapacity();
        if (list) |entries| self.implicit_items.appendSlice(entries.items) catch return &.{};

        var explicit = std.StringHashMap(void).init(self.allocator);
        defer explicit.deinit();
        for (self.implicit_items.items) |entry| {
            if (entry == .command) {
                explicit.put(entry.command.command.id, {}) catch {};
                if (entry.command.alt) |alt| explicit.put(alt.id, {}) catch {};
            }
        }
        var iterator = self.commands.iterator();
        while (iterator.next()) |entry| {
            if (explicit.contains(entry.key_ptr.*)) continue;
            self.implicit_items.append(.{ .command = .{ .command = entry.value_ptr.* } }) catch return self.implicit_items.items;
        }
        return self.implicit_items.items;
    }
};

/// The registries an `Action2` registers into.
pub const ActionRegistries = struct {
    commands: *commands.CommandRegistry,
    keybindings: *keybindings_registry.KeybindingsRegistry,
    menus: *MenuRegistry,
};

pub const MenuRegistration = struct {
    id: MenuId,
    group: []const u8 = "",
    order: i64 = 0,
    when: ?*const contextkey.Expr = null,
    // Represents the upstream menu item's explicit precondition: null.
    omit_precondition: bool = false,
    is_hidden_by_default: bool = false,
};

pub const ActionRun = *const fn (context: *anyopaque, accessor: ?*const anyopaque) anyerror!void;

pub const Action2 = struct {
    command: ICommandAction,
    f1: bool = false,
    menus: []const MenuRegistration = &.{},
    keybindings: []const keybindings_registry.IKeybindingRule = &.{},
    context: *anyopaque,
    run_fn: ActionRun,
};

pub const ActionRegistration = struct {
    allocator: Allocator,
    commands: *commands.CommandRegistry,
    id: []const u8,
    context: *anyopaque,
    run_fn: ActionRun,
    menus: std.ArrayList(MenuRegistry.Registration) = .empty,
    keybindings: std.ArrayList(keybindings_registry.Registration) = .empty,
    exprs: contextkey.ContextKeyExpr,

    fn run(context: *anyopaque) anyerror!void {
        const self: *ActionRegistration = @ptrCast(@alignCast(context));
        return self.run_fn(self.context, null);
    }

    pub fn dispose(self: *ActionRegistration) void {
        if (self.commands.get(self.id)) |command| {
            if (command.context == @as(*anyopaque, @ptrCast(self))) self.commands.unregister(self.id);
        }
        for (self.menus.items) |menu| menu.dispose();
        for (self.keybindings.items) |*rule| rule.dispose();
        self.menus.deinit(self.allocator);
        self.keybindings.deinit(self.allocator);
        self.exprs.deinit();
        self.allocator.destroy(self);
    }
};

/// Port of registerAction2. The registration owns the command handler and the
/// context expressions composed during registration. Descriptors borrow their
/// strings and callback context for the registration lifetime.
pub fn registerAction2(registries: ActionRegistries, action2: Action2) !*ActionRegistration {
    const command = action2.command;
    if (registries.commands.get(command.id) != null) return error.DuplicateCommand;
    const allocator = registries.commands.allocator;
    const registration = try allocator.create(ActionRegistration);
    registration.* = .{
        .allocator = allocator,
        .commands = registries.commands,
        .id = command.id,
        .context = action2.context,
        .run_fn = action2.run_fn,
        .exprs = contextkey.ContextKeyExpr.init(allocator),
    };
    errdefer registration.dispose();
    try registration.menus.ensureTotalCapacity(allocator, action2.menus.len + @as(usize, if (action2.f1) 2 else 0));
    try registration.keybindings.ensureTotalCapacity(allocator, action2.keybindings.len);
    try registries.commands.register(.{ .id = command.id, .context = registration, .run = ActionRegistration.run });
    for (action2.menus) |menu| {
        var menu_command = command;
        if (menu.omit_precondition) menu_command.precondition = null;
        registration.menus.appendAssumeCapacity(try registries.menus.appendMenuItemTracked(menu.id, .{
            .command = menu_command,
            .when = menu.when,
            .group = menu.group,
            .order = menu.order,
            .is_hidden_by_default = menu.is_hidden_by_default,
        }));
    }
    if (action2.f1) {
        registration.menus.appendAssumeCapacity(try registries.menus.appendMenuItemTracked(menu_ids.CommandPalette, .{
            .command = command,
            .when = command.precondition,
        }));
        registration.menus.appendAssumeCapacity(try registries.menus.addCommandTracked(command));
    }
    for (action2.keybindings) |binding| {
        var rule = binding;
        rule.id = command.id;
        if (command.precondition) |precondition| rule.when = try registration.exprs.andExpr(&.{ precondition, rule.when });
        registration.keybindings.appendAssumeCapacity(try registries.keybindings.registerKeybindingRule(rule));
    }
    return registration;
}

test "menu registry keeps insertion order and kinds" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();

    try registry.appendMenuItem(menu_ids.EditorTitle, .{
        .command = .{ .id = "a", .title = "A" },
        .order = 1,
    });
    try registry.appendSubmenuItem(menu_ids.EditorTitle, .{
        .title = "More",
        .submenu = menu_ids.EditorTitleContext,
        .order = 2,
    });

    const items = registry.getMenuItems(menu_ids.EditorTitle);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(items[0] == .command);
    try std.testing.expectEqualStrings("a", items[0].command.command.id);
    try std.testing.expect(items[1] == .submenu);
    try std.testing.expectEqualStrings("More", items[1].submenu.title);

    try std.testing.expectEqual(@as(usize, 0), registry.getMenuItems(menu_ids.EditorContext).len);
}

test "Action2 registers command, keybinding and menu contribution" {
    const allocator = std.testing.allocator;
    const key_codes = @import("../../../base/common/keyCodes.zig");
    const Counter = struct {
        count: usize = 0,
        fn run(context: *anyopaque, _: ?*const anyopaque) anyerror!void {
            const counter: *@This() = @ptrCast(@alignCast(context));
            counter.count += 1;
        }
    };
    var counter = Counter{};

    var command_registry = commands.CommandRegistry.init(allocator);
    defer command_registry.deinit();
    var keybinding_registry = keybindings_registry.KeybindingsRegistry.init(allocator);
    defer keybinding_registry.deinit();
    var menu_registry = MenuRegistry.init(allocator);
    defer menu_registry.deinit();

    const registries = ActionRegistries{
        .commands = &command_registry,
        .keybindings = &keybinding_registry,
        .menus = &menu_registry,
    };

    const descriptor = Action2{
        .command = .{ .id = "test.action", .title = "Test Action" },
        .context = &counter,
        .run_fn = Counter.run,
        .keybindings = &.{.{
            .id = "",
            .weight = 200,
            .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyT) },
        }},
        .menus = &.{.{ .id = menu_ids.CommandPalette, .group = "navigation", .order = 5 }},
    };
    const registration = try registerAction2(registries, descriptor);
    defer registration.dispose();
    try std.testing.expectError(error.DuplicateCommand, registerAction2(registries, descriptor));
    try std.testing.expect(menu_registry.getCommand("test.action") == null);

    try std.testing.expect(try command_registry.execute("test.action"));
    try std.testing.expectEqual(@as(usize, 1), counter.count);

    const items = menu_registry.getMenuItems(menu_ids.CommandPalette);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("Test Action", items[0].command.command.title);
    try std.testing.expectEqual(@as(i64, 5), items[0].command.order);

    var hidden = descriptor;
    hidden.command = .{ .id = "test.internal", .title = "Internal" };
    hidden.menus = &.{};
    hidden.keybindings = &.{};
    const internal = try registerAction2(registries, hidden);
    defer internal.dispose();
    try std.testing.expect(try command_registry.execute(hidden.command.id));
    try std.testing.expectEqual(@as(usize, 1), menu_registry.getMenuItems(menu_ids.CommandPalette).len);

    const precondition = contextkey.Expr{ .Defined = "editorFocus" };
    var visible = hidden;
    visible.command = .{ .id = "test.visible", .title = "Visible", .precondition = &precondition };
    visible.f1 = true;
    const palette_action = try registerAction2(registries, visible);
    const palette = menu_registry.getMenuItems(menu_ids.CommandPalette);
    try std.testing.expectEqual(@as(usize, 2), palette.len);
    try std.testing.expect(palette[1].command.when == &precondition);
    try std.testing.expect(menu_registry.getCommand(visible.command.id) != null);
    palette_action.dispose();
    try std.testing.expectEqual(@as(usize, 1), menu_registry.getMenuItems(menu_ids.CommandPalette).len);
    try std.testing.expect(menu_registry.getCommand(visible.command.id) == null);
    try std.testing.expect(command_registry.get(visible.command.id) == null);

    const keybindings = try keybinding_registry.getDefaultKeybindings(allocator);
    defer allocator.free(keybindings);
    try std.testing.expectEqual(@as(usize, 1), keybindings.len);
    try std.testing.expectEqualStrings("test.action", keybindings[0].command.?);
}

test "command palette shows implicit commands once" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();

    try registry.addCommand(.{ .id = "a", .title = "A" });
    try registry.addCommand(.{ .id = "b", .title = "B" });
    try registry.appendMenuItem(menu_ids.CommandPalette, .{
        .command = .{ .id = "a", .title = "Explicit A" },
    });

    const items = registry.getMenuItems(menu_ids.CommandPalette);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("Explicit A", items[0].command.command.title);
    try std.testing.expectEqualStrings("b", items[1].command.command.id);
}
