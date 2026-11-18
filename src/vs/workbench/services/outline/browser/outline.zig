// Port of `src/vs/workbench/services/outline/browser/outline.ts`.
//
// The browser outline service hands an `IEditorPane` to outline creators and
// returns a tree/list-backed outline used by the Outline view, breadcrumbs and
// quick pick. The terminal port keeps the portable contract: creators match a
// text editor, return an `IOutline`, and expose a breadcrumbs data source plus
// a reveal operation.
//
// Terminal adaptations (documented in README and docs/terminal-ui.md):
// - `IOutlineListConfig` is reduced to the breadcrumbs data source. The tree
//   data source, renderers, comparator and picker quick-pick source are only
//   needed by the browser Outline view, which is not ported.
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

/// The portable subset of upstream `IOutlineListConfig`.
pub const OutlineListConfig = struct {
    breadcrumbs_data_source: BreadcrumbsDataSource,
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
    revealFn: *const fn (context: *anyopaque, element: *anyopaque, options: RevealOptions) anyerror!void,
    disposeFn: *const fn (context: *anyopaque) void,

    pub fn reveal(self: *IOutline, element: *anyopaque, options: RevealOptions) !void {
        try self.revealFn(self.context, element, options);
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
