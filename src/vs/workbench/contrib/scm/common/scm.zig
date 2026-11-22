// Port of `src/vs/workbench/contrib/scm/common/scm.ts`.
//
// Terminal adaptations:
// - Resources are local filesystem paths (`[]const u8`) instead of `URI`; the
//   terminal workbench is single-process and has no virtual file system
//   provider for SCM resources.
// - `Event` fields become emitters reachable through accessors, and
//   `IObservable` provider properties (count, context value, ...) become plain
//   fields refreshed by the provider. The observable system is not ported.
// - Menus, artifacts, input validation/history and the multi-repository view
//   service are not ported. The history provider is exposed here so the Graph
//   view can reach it.
const std = @import("std");

const languages = @import("../../../../editor/common/languages.zig");
const language_selector = @import("../../../../editor/common/languageSelector.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const history = @import("./history.zig");

pub const Command = languages.Command;
pub const Selector = language_selector.Selector;

pub const VIEWLET_ID = "workbench.view.scm";
pub const VIEW_PANE_ID = "workbench.scm";
pub const REPOSITORIES_VIEW_PANE_ID = "workbench.scm.repositories";

pub const ViewMode = enum { list, tree };

pub const ISCMResourceDecorations = struct {
    /// File-decoration tooltip. The Git provider stores the upstream status
    /// text here (`Modified`, `Index Added`, `Conflict: Both Modified`, ...);
    /// the SCM view uses it for the `scm.defaultViewSortKey=status` ordering.
    /// Terminal rows have no hover, so the text is not painted directly.
    tooltip: ?[]const u8 = null,
    strike_through: bool = false,
    faded: bool = false,
    /// Terminal projection of the Git extension's file decoration
    /// (`FileDecoration.letter`). The workbench has no general file
    /// decoration service, so the SCM provider carries the badge letter the
    /// resource row paints.
    letter: ?[]const u8 = null,
    /// Theme color of the badge letter (for Git
    /// `gitDecoration.modifiedResourceForeground`, ...).
    color: ?[]const u8 = null,
};

/// A changed resource in a resource group. The terminal resource rows paint the
/// relative path and open the diff through `open`.
pub const ISCMResource = struct {
    context: *anyopaque,
    resource_group: *ISCMResourceGroup,
    source_path: []const u8,
    decorations: ISCMResourceDecorations = .{},
    context_value: ?[]const u8 = null,
    command: ?Command = null,
    multi_diff_original_path: ?[]const u8 = null,
    multi_diff_modified_path: ?[]const u8 = null,
    open_fn: ?*const fn (context: *anyopaque, preserve_focus: bool) anyerror!void = null,

    pub fn open(self: ISCMResource, preserve_focus: bool) !void {
        const function = self.open_fn orelse return;
        return function(self.context, preserve_focus);
    }
};

pub const ISCMResourceGroup = struct {
    context: *anyopaque,
    id: []const u8,
    provider: *ISCMProvider,
    label: []const u8,
    context_value: ?[]const u8 = null,
    hide_when_empty: bool = false,
    multi_diff_editor_enable_view_changes: bool = false,
    resources_fn: *const fn (context: *anyopaque) []const ISCMResource,
    on_did_change_resources: *Emitter(void),
    on_did_change: *Emitter(void),

    pub fn resources(self: ISCMResourceGroup) []const ISCMResource {
        return self.resources_fn(self.context);
    }
};

/// A terminal SCM provider (for Git: groups, resources and counts).
pub const ISCMProvider = struct {
    context: *anyopaque,
    id: []const u8,
    parent_id: ?[]const u8 = null,
    provider_id: []const u8,
    label: []const u8,
    name: []const u8,
    root_path: ?[]const u8 = null,
    is_hidden: bool = false,
    /// Terminal projection of the upstream `count` observable.
    count: ?usize = null,
    /// Terminal projection of the upstream `activeRepositoryName` observable.
    active_repository_name: ?[]const u8 = null,
    /// Terminal projection of the upstream `contextValue` observable.
    context_value: ?[]const u8 = null,
    /// Short terminal detail for the repository row (for Git, the branch name).
    detail: ?[]const u8 = null,
    status_bar_commands: []const Command = &.{},
    /// Terminal projection of the upstream `historyProvider` observable. Null
    /// when the provider cannot supply history (for example no Git repository).
    history_provider: ?*history.ISCMHistoryProvider = null,
    groups_fn: *const fn (context: *anyopaque) []const *ISCMResourceGroup,
    on_did_change_resource_groups: *Emitter(void),
    on_did_change_resources: *Emitter(void),
    dispose_fn: ?*const fn (context: *anyopaque) void = null,

    pub fn groups(self: ISCMProvider) []const *ISCMResourceGroup {
        return self.groups_fn(self.context);
    }

    pub fn dispose(self: ISCMProvider) void {
        if (self.dispose_fn) |function| function(self.context);
    }
};

/// Terminal port of `ISCMInput`. The input text, placeholder, enablement and
/// visibility are plain fields refreshed through accessors; the history,
/// validation and focus events of the browser input are not ported.
pub const ISCMInput = struct {
    context: *anyopaque,
    value_fn: *const fn (context: *anyopaque) []const u8,
    set_value_fn: *const fn (context: *anyopaque, value: []const u8, from_keyboard: bool) void,
    placeholder_fn: *const fn (context: *anyopaque) []const u8,
    set_placeholder_fn: *const fn (context: *anyopaque, placeholder: []const u8) void,
    enabled_fn: *const fn (context: *anyopaque) bool,
    set_enabled_fn: *const fn (context: *anyopaque, enabled: bool) void,
    visible_fn: *const fn (context: *anyopaque) bool,
    set_visible_fn: *const fn (context: *anyopaque, visible: bool) void,
    on_did_change: *Emitter(void),

    pub fn value(self: ISCMInput) []const u8 {
        return self.value_fn(self.context);
    }

    pub fn setValue(self: ISCMInput, new_value: []const u8, from_keyboard: bool) void {
        self.set_value_fn(self.context, new_value, from_keyboard);
    }

    pub fn placeholder(self: ISCMInput) []const u8 {
        return self.placeholder_fn(self.context);
    }

    pub fn setPlaceholder(self: ISCMInput, new_placeholder: []const u8) void {
        self.set_placeholder_fn(self.context, new_placeholder);
    }

    pub fn enabled(self: ISCMInput) bool {
        return self.enabled_fn(self.context);
    }

    pub fn setEnabled(self: ISCMInput, is_enabled: bool) void {
        self.set_enabled_fn(self.context, is_enabled);
    }

    pub fn visible(self: ISCMInput) bool {
        return self.visible_fn(self.context);
    }

    pub fn setVisible(self: ISCMInput, is_visible: bool) void {
        self.set_visible_fn(self.context, is_visible);
    }
};

pub const ISCMRepository = struct {
    context: *anyopaque,
    id: []const u8,
    provider: ISCMProvider,
    input: ISCMInput,
    dispose_fn: *const fn (context: *anyopaque) void,

    pub fn dispose(self: ISCMRepository) void {
        self.dispose_fn(self.context);
    }
};

/// Terminal port of `ISCMService`. `get_repository_by_path_fn` performs the
/// upstream longest-root match for local filesystem paths.
pub const ISCMService = struct {
    context: *anyopaque,
    repositories_fn: *const fn (context: *anyopaque) []const ISCMRepository,
    repository_count_fn: *const fn (context: *anyopaque) usize,
    register_scm_provider_fn: *const fn (context: *anyopaque, provider: *ISCMProvider) anyerror!*ISCMRepository,
    get_repository_by_id_fn: *const fn (context: *anyopaque, id: []const u8) ?*ISCMRepository,
    get_repository_by_path_fn: *const fn (context: *anyopaque, path: []const u8) ?*ISCMRepository,
    on_did_add_repository: *Emitter(*ISCMRepository),
    on_did_remove_repository: *Emitter(*ISCMRepository),

    pub fn repositories(self: ISCMService) []const ISCMRepository {
        return self.repositories_fn(self.context);
    }

    pub fn repositoryCount(self: ISCMService) usize {
        return self.repository_count_fn(self.context);
    }

    pub fn registerSCMProvider(self: ISCMService, provider: *ISCMProvider) !*ISCMRepository {
        return self.register_scm_provider_fn(self.context, provider);
    }

    pub fn getRepository(self: ISCMService, id: []const u8) ?*ISCMRepository {
        return self.get_repository_by_id_fn(self.context, id);
    }

    pub fn getRepositoryByPath(self: ISCMService, path: []const u8) ?*ISCMRepository {
        return self.get_repository_by_path_fn(self.context, path);
    }
};
