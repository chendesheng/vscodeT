// Port of `src/vs/workbench/services/outline/browser/outline.ts`.
//
// The browser outline service hands an `IEditorPane` to outline creators and
// returns a tree/list-backed outline used by the Outline view, breadcrumbs and
// quick pick. The terminal port keeps the portable contract: creators match a
// text editor, return an `IOutline`, and expose a breadcrumbs data source plus
// a reveal operation.
//
// Terminal adaptations (documented in README and docs/terminal-ui.md):
// - `IOutlineListConfig` keeps the breadcrumbs data source plus a terminal
//   tree snapshot, comparator and kind filter for the Outline side panel. The
//   browser renderer/delegate and quick-pick source are replaced by the
//   shared `ListWidget` and the breadcrumb popup.
// - `IEditorPane` is replaced by `OutlineEditor`, a small descriptor the TUI
//   fills from its tab. There is no extension host yet, so a creator gets the
//   descriptor synchronously; asynchronous provider results arrive through
//   `IOutline.on_did_change`.
// - `OutlineTarget` keeps the upstream bit values.

const std = @import("std");
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const OutlineTarget = enum(u8) {
    OutlinePane = 1,
    Breadcrumbs = 2,
    QuickPick = 4,
};

/// The terminal stand-in for upstream `IEditorPane`. A creator may cast
/// `context` when it is registered by the TUI; portable creators should only
/// rely on `resource` and `language_id`.
pub const OutlineEditor = struct {
    context: *anyopaque,
    resource: ?[]const u8,
    language_id: []const u8,
};

/// One symbol entry in the breadcrumbs path.
pub const OutlineElement = struct {
    /// Opaque symbol payload owned by the provider.
    element: *anyopaque,
    label: []const u8,
    /// Upstream `SymbolKind`; hints the terminal symbol glyph.
    symbol_kind: ?u32 = null,
};

pub const BreadcrumbsOutlineElement = OutlineElement;

pub const BreadcrumbsDataSource = struct {
    context: *anyopaque,
    get_breadcrumb_elements: *const fn (context: *anyopaque) []const BreadcrumbsOutlineElement,
};

/// Upstream `IOutlineComparator`: sorting modes used by both the outline pane
/// and the breadcrumb outline picker.
pub const OutlineComparator = struct {
    context: *anyopaque,
    compare_by_position: *const fn (context: *anyopaque, a: *anyopaque, b: *anyopaque) std.math.Order,
    compare_by_type: *const fn (context: *anyopaque, a: *anyopaque, b: *anyopaque) std.math.Order,
    compare_by_name: *const fn (context: *anyopaque, a: *anyopaque, b: *anyopaque) std.math.Order,
};

/// One node returned by the terminal tree data source. The element pointer is
/// the same opaque handle `IOutline.reveal` accepts.
pub const TreeElement = struct {
    element: *anyopaque,
    label: []const u8,
    symbol_kind: ?u32 = null,
    is_group: bool = false,
    collapsible: bool = false,
    id: []const u8 = "",
    marker_count: usize = 0,
    marker_severity: ?u32 = null,
    deprecated: bool = false,
    children: []const TreeElement = &.{},
};

/// Upstream `IDataSource<IOutline<E>, E>` reduced to a tree snapshot. The
/// provider owns the returned tree until its next change.
pub const TreeDataSource = struct {
    context: *anyopaque,
    get_roots: *const fn (context: *anyopaque) []const TreeElement,
};

/// Upstream `DocumentSymbolFilter` hook. The outline pane asks whether an
/// element's symbol kind is enabled by the `outline.show*` settings.
pub const OutlineFilter = struct {
    context: *anyopaque,
    is_visible: *const fn (context: *anyopaque, element: *anyopaque) bool,
};

/// The portable subset of upstream `IOutlineListConfig`.
pub const OutlineListConfig = struct {
    breadcrumbs_data_source: BreadcrumbsDataSource,
    /// Supplied by providers that can populate the Outline side panel. The
    /// breadcrumb-only path leaves it null.
    tree_data_source: ?TreeDataSource = null,
    comparator: ?OutlineComparator = null,
    filter: ?OutlineFilter = null,
    /// Upstream `options.collapseByDefault` for the outline pane.
    collapse_by_default: bool = false,
};

pub const OutlineChangeEvent = struct {
    affect_only_active_element: bool = false,
};

pub const RevealOptions = struct {
    preserve_focus: bool = false,
    select: bool = false,
    side_by_side: bool = false,
};

/// The `IOutline` interface. Concrete adapters from an outline provider expose
/// this value; the context lifetime is tied to the provider's outline object.
pub const IOutline = struct {
    context: *anyopaque,
    uri: ?[]const u8,
    outline_kind: []const u8,
    is_empty: bool = false,
    config: OutlineListConfig,
    on_did_change: ?*Emitter(OutlineChangeEvent) = null,
    /// Upstream `activeElement`.
    active_element_fn: ?*const fn (context: *anyopaque) ?*anyopaque = null,
    /// The parent of an element, used by the breadcrumb outline picker to list
    /// siblings. Upstream gets it from the tree element's `parent`.
    parent_fn: ?*const fn (context: *anyopaque, element: *anyopaque) ?*anyopaque = null,
    /// Keeps tree elements alive while a terminal picker holds their addresses
    /// across provider refreshes. The picker owns the returned outline.
    retain_picker_input: ?*const fn (*anyopaque) anyerror!*IOutline = null,
    revealFn: *const fn (context: *anyopaque, element: *anyopaque, options: RevealOptions) anyerror!void,
    disposeFn: *const fn (context: *anyopaque) void,

    pub fn reveal(self: *IOutline, element: *anyopaque, options: RevealOptions) !void {
        try self.revealFn(self.context, element, options);
    }

    pub fn activeElement(self: *IOutline) ?*anyopaque {
        const callback = self.active_element_fn orelse return null;
        return callback(self.context);
    }

    pub fn getParent(self: *IOutline, element: *anyopaque) ?*anyopaque {
        const callback = self.parent_fn orelse return null;
        return callback(self.context, element);
    }

    pub fn dispose(self: *IOutline) void {
        self.disposeFn(self.context);
    }
};

pub const IOutlineCreator = struct {
    context: *anyopaque,
    matches: *const fn (context: *anyopaque, editor: OutlineEditor) bool,
    create_outline: *const fn (
        context: *anyopaque,
        editor: OutlineEditor,
        target: OutlineTarget,
    ) anyerror!?*IOutline,
};
