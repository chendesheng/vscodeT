// Port of the portable constants and view state from
// `src/vs/workbench/contrib/outline/browser/outline.ts` and
// `outlineViewState.ts`.
//
// The terminal has no context-key service or persisted workspace storage for
// the outline view. The context-key identifiers are kept as the command ids the
// title actions toggle, and `OutlineViewState` owns the same three settings
// (follow cursor, filter on type, sort order) with upstream defaults.

const std = @import("std");
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const OutlineSortOrder = enum(u2) {
    ByPosition = 0,
    ByName = 1,
    ByKind = 2,
};

/// Upstream `IOutlinePane`.
pub const IOutlinePane = struct {
    pub const Id = "outline";
};

/// Upstream `IOutlinePane.Id` as a module constant.
pub const outline_id = IOutlinePane.Id;

/// Upstream `OutlineConfigKeys`.
pub const OutlineConfigKeys = struct {
    pub const icons = "outline.icons";
    pub const collapse_items = "outline.collapseItems";
    pub const problems_enabled = "outline.problems.enabled";
    pub const problems_colors = "outline.problems.colors";
    pub const problems_badges = "outline.problems.badges";
};

/// Upstream `OutlineConfigCollapseItemsValues`.
pub const OutlineConfigCollapseItemsValues = struct {
    pub const collapsed = "alwaysCollapse";
    pub const expanded = "alwaysExpand";
};

/// Upstream `IOutlineViewState`, including its change event.
pub const OutlineViewState = struct {
    follow_cursor: bool = false,
    filter_on_type: bool = true,
    sort_by: OutlineSortOrder = .ByPosition,
    on_did_change: Emitter(void),

    pub fn init(allocator: std.mem.Allocator) OutlineViewState {
        return .{ .on_did_change = Emitter(void).init(allocator) };
    }

    pub fn deinit(self: *OutlineViewState) void {
        self.on_did_change.deinit();
    }

    pub fn setFollowCursor(self: *OutlineViewState, value: bool) !void {
        if (self.follow_cursor == value) return;
        self.follow_cursor = value;
        try self.on_did_change.fire({});
    }

    pub fn setFilterOnType(self: *OutlineViewState, value: bool) !void {
        if (self.filter_on_type == value) return;
        self.filter_on_type = value;
        try self.on_did_change.fire({});
    }

    pub fn setSortBy(self: *OutlineViewState, value: OutlineSortOrder) !void {
        if (self.sort_by == value) return;
        self.sort_by = value;
        try self.on_did_change.fire({});
    }
};

/// Upstream `SymbolKind` filter keys used by `DocumentSymbolFilter`.
pub fn showConfigForKind(kind: u32) []const u8 {
    return switch (kind) {
        1 => "outline.showFiles",
        2 => "outline.showModules",
        3 => "outline.showNamespaces",
        4 => "outline.showPackages",
        5 => "outline.showClasses",
        6 => "outline.showMethods",
        7 => "outline.showProperties",
        8 => "outline.showFields",
        9 => "outline.showConstructors",
        10 => "outline.showEnums",
        11 => "outline.showInterfaces",
        12 => "outline.showFunctions",
        13 => "outline.showVariables",
        14 => "outline.showConstants",
        15 => "outline.showStrings",
        16 => "outline.showNumbers",
        17 => "outline.showBooleans",
        18 => "outline.showArrays",
        19 => "outline.showObjects",
        20 => "outline.showKeys",
        21 => "outline.showNull",
        22 => "outline.showEnumMembers",
        23 => "outline.showStructs",
        24 => "outline.showEvents",
        25 => "outline.showOperators",
        26 => "outline.showTypeParameters",
        else => "outline.showClasses",
    };
}

/// Breadcrumb kind filter keys (`breadcrumbs.show*`).
pub fn breadcrumbConfigForKind(kind: u32) []const u8 {
    const outline_key = showConfigForKind(kind);
    const suffix = outline_key["outline.".len..];
    return switch (kind) {
        1 => "breadcrumbs.showFiles",
        2 => "breadcrumbs.showModules",
        3 => "breadcrumbs.showNamespaces",
        4 => "breadcrumbs.showPackages",
        5 => "breadcrumbs.showClasses",
        6 => "breadcrumbs.showMethods",
        7 => "breadcrumbs.showProperties",
        8 => "breadcrumbs.showFields",
        9 => "breadcrumbs.showConstructors",
        10 => "breadcrumbs.showEnums",
        11 => "breadcrumbs.showInterfaces",
        12 => "breadcrumbs.showFunctions",
        13 => "breadcrumbs.showVariables",
        14 => "breadcrumbs.showConstants",
        15 => "breadcrumbs.showStrings",
        16 => "breadcrumbs.showNumbers",
        17 => "breadcrumbs.showBooleans",
        18 => "breadcrumbs.showArrays",
        19 => "breadcrumbs.showObjects",
        20 => "breadcrumbs.showKeys",
        21 => "breadcrumbs.showNull",
        22 => "breadcrumbs.showEnumMembers",
        23 => "breadcrumbs.showStructs",
        24 => "breadcrumbs.showEvents",
        25 => "breadcrumbs.showOperators",
        26 => "breadcrumbs.showTypeParameters",
        else => suffix,
    };
}

test "OutlineViewState: upstream defaults and change events" {
    var state = OutlineViewState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expect(!state.follow_cursor);
    try std.testing.expect(state.filter_on_type);
    try std.testing.expectEqual(OutlineSortOrder.ByPosition, state.sort_by);

    const Counter = struct {
        var count: usize = 0;
        fn changed(_: void, ctx: *usize) anyerror!void {
            ctx.* += 1;
        }
    };
    var count: usize = 0;
    _ = try state.on_did_change.listen(&count, Counter.changed);
    try state.setFollowCursor(true);
    try state.setSortBy(.ByName);
    try state.setFilterOnType(false);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("outline.showFunctions", showConfigForKind(12));
    try std.testing.expectEqualStrings("breadcrumbs.showFunctions", breadcrumbConfigForKind(12));
}
