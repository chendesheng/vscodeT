// Portable subset of `src/vs/platform/quickinput/common/quickInput.ts`.
//
// Exposes quick access and one-shot pick results and visibility events through
// IQuickInputService. The quick-pick data model
// includes items, separators, activation modes and pick ownership options.
// Items can also carry row actions and resolved shortcut keycaps.

const std = @import("std");

pub const IPickOptions = struct {
    placeholder: []const u8 = "",
    active_id: ?[]const u8 = null,
};

/// Terminal Promise adaptation: a dismissed pick returns null, an accepted
/// pick borrows its item until the result handler completes.
pub const PickResultHandler = *const fn (*anyopaque, ?*const Item) anyerror!void;

pub const IQuickInputService = struct {
    quick_access: @import("quickAccess.zig").IQuickAccessController,
    context: *anyopaque,
    pick_fn: *const fn (*anyopaque, []const QuickPickItem, IPickOptions, PickResultHandler, *anyopaque) anyerror!void,
    on_show: *@import("../../../base/common/event.zig").Emitter(void),
    on_hide: *@import("../../../base/common/event.zig").Emitter(void),

    pub fn pick(self: IQuickInputService, items: []const QuickPickItem, options: IPickOptions, handler: PickResultHandler, context: *anyopaque) !void {
        try self.pick_fn(self.context, items, options, handler, context);
    }
};
pub const quick_input_service_id = @import("../../instantiation/common/instantiation.zig").ServiceIdentifier(IQuickInputService, "quickInputService");

/// Matched ranges borrowed from the pick provider. Mirrors upstream
/// `IQuickPickItemHighlights` for the two fields the terminal renders.
pub const Highlights = struct {
    label: []const @import("../../../base/common/filters.zig").Match = &.{},
    description: []const @import("../../../base/common/filters.zig").Match = &.{},
};

pub const ItemAction = enum { open_side, configure_keybinding, remove_history };

pub const Item = struct {
    actions: []const ItemAction = &.{},
    file_icon: bool = false,
    keycaps: []const []const u8 = &.{},
    id: []const u8 = "",
    label: []const u8,
    description: []const u8 = "",
    detail: []const u8 = "",
    highlights: Highlights = .{},
    /// Runs when the item is accepted. The picker hides before this is called.
    accept_context: ?*anyopaque = null,
    accept: ?*const fn (context: *anyopaque) anyerror!void = null,
};

pub const Separator = struct {
    id: []const u8 = "",
    label: []const u8 = "",
};

pub const QuickPickItem = union(enum) {
    item: Item,
    separator: Separator,

    pub fn id(self: QuickPickItem) []const u8 {
        return switch (self) {
            .item => |value| value.id,
            .separator => |value| value.id,
        };
    }
};

pub const ItemActivation = enum {
    none,
    first,
    second,
    last,
};

pub const QuickPickOptions = struct {
    use_separators: bool = true,
};

test "quickInput: item and separator shape" {
    const item = QuickPickItem{ .item = .{ .id = "a", .label = "Alpha" } };
    const separator = QuickPickItem{ .separator = .{ .label = "group" } };
    try std.testing.expectEqualStrings("a", item.id());
    try std.testing.expectEqualStrings("", separator.id());
    try std.testing.expect(separator == .separator);
}
