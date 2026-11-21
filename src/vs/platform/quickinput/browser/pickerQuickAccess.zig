// Port of the portable `PickerQuickAccessProvider` flow in
// `src/vs/platform/quickinput/browser/pickerQuickAccess.ts`.
//
// The provider supplies already filtered picks; this helper applies the pick
// filter trimming, the no-results pick, active-item preservation across
// refreshes, and the "hide then run accept" order. Upstream's fast/slow
// promises, background accept, buttons and disposables are not ported: the
// TUI providers are synchronous and the picker is persistent.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cancellation = @import("../../../base/common/cancellation.zig");
const CancellationToken = cancellation.CancellationToken;
const quick_input = @import("../common/quickInput.zig");
const QuickPickItem = quick_input.QuickPickItem;
const QuickPick = @import("./quickInput.zig").QuickPick;

pub const PickerOptions = struct {
    prefix: []const u8,
    no_results_pick: ?QuickPickItem = null,
    can_accept_in_background: bool = false,
    should_skip_trim_pick_filter: bool = false,
};

pub const PickerImpl = struct {
    context: *anyopaque,
    /// Returns picks (owned by the provider until its next call) or null to
    /// leave the current items untouched.
    get_picks: *const fn (
        context: *anyopaque,
        filter: []const u8,
        allocator: Allocator,
    ) anyerror!?[]QuickPickItem,
    is_busy: ?*const fn (context: *anyopaque) bool = null,
};

pub fn provide(
    impl: PickerImpl,
    options: PickerOptions,
    picker: *QuickPick,
    token: CancellationToken,
) !void {
    return update(impl, options, picker, token);
}

pub fn refresh(
    impl: PickerImpl,
    options: PickerOptions,
    picker: *QuickPick,
) !void {
    return update(impl, options, picker, null);
}

pub fn accept(picker: *QuickPick) !void {
    const item = picker.selectedItem() orelse return;
    const accept_fn = item.accept;
    const accept_context = item.accept_context;
    picker.hide();
    if (accept_fn) |callback| {
        if (accept_context) |context| try callback(context);
    }
}

fn update(
    impl: PickerImpl,
    options: PickerOptions,
    picker: *QuickPick,
    token: ?CancellationToken,
) !void {
    if (token) |value| {
        if (value.isCancellationRequested()) return;
    }

    var filter_value: []const u8 = picker.value.items;
    if (filter_value.len >= options.prefix.len and
        std.mem.startsWith(u8, filter_value, options.prefix))
    {
        filter_value = filter_value[options.prefix.len..];
    }
    if (!options.should_skip_trim_pick_filter) {
        filter_value = std.mem.trim(u8, filter_value, " \t");
    }

    // The previous item's slices may be freed by `get_picks`; remember the id.
    var previous_id: ?[]u8 = null;
    defer if (previous_id) |id| picker.allocator.free(id);
    if (picker.activeItem()) |active| {
        if (active.id.len > 0) {
            previous_id = try picker.allocator.dupe(u8, active.id);
        }
    }

    // The provider may return null while an asynchronous search is in flight.
    // Keep the busy indicator accurate on that path as well as after items are
    // published.
    if (impl.is_busy) |is_busy| picker.setBusy(is_busy(impl.context));

    const picks = try impl.get_picks(impl.context, filter_value, picker.allocator) orelse {
        if (impl.is_busy) |is_busy| picker.setBusy(is_busy(impl.context));
        return;
    };
    if (token) |value| {
        if (value.isCancellationRequested()) return;
    }

    var items = picks;
    var owned_no_results: ?[]QuickPickItem = null;
    defer if (owned_no_results) |owned| picker.allocator.free(owned);

    if (items.len == 0 and filter_value.len > 0) {
        if (options.no_results_pick) |pick| {
            owned_no_results = try picker.allocator.alloc(QuickPickItem, 1);
            owned_no_results.?[0] = pick;
            items = owned_no_results.?;
        }
    }

    try picker.setItems(items);
    if (previous_id) |id| {
        for (picker.items.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.id(), id)) {
                picker.setActiveIndex(index);
                break;
            }
        }
    }
    if (impl.is_busy) |is_busy| picker.setBusy(is_busy(impl.context));
}

const PickerTestState = struct {
    filter: [64]u8 = std.mem.zeroes([64]u8),
    filter_len: usize = 0,
    accepted: usize = 0,
    hidden_first: bool = false,
    picker: ?*QuickPick = null,
    items: [1]QuickPickItem = .{
        .{ .item = .{
            .id = "a",
            .label = "Alpha",
            .accept_context = null,
            .accept = null,
        } },
    },
    empty: [0]QuickPickItem = .{},
    fn getPicks(context: *anyopaque, filter: []const u8, _: Allocator) anyerror!?[]QuickPickItem {
        const self: *@This() = @ptrCast(@alignCast(context));
        const copy_len = @min(filter.len, self.filter.len);
        @memcpy(self.filter[0..copy_len], filter[0..copy_len]);
        self.filter_len = copy_len;
        if (std.mem.eql(u8, filter, "none")) return self.empty[0..];
        self.items[0].item.accept_context = self;
        self.items[0].item.accept = @This().acceptItem;
        return self.items[0..];
    }
    fn acceptItem(context: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.picker) |picker| self.hidden_first = !picker.visible;
        self.accepted += 1;
    }
};

test "PickerQuickAccessProvider: no results, filtering and accept ordering" {
    var state = PickerTestState{};
    var picker = QuickPick.init(std.testing.allocator);
    defer picker.deinit();
    state.picker = &picker;

    const options = PickerOptions{
        .prefix = "",
        .no_results_pick = .{ .item = .{ .label = "No matching results" } },
    };
    const impl = PickerImpl{ .context = &state, .get_picks = PickerTestState.getPicks };

    var source = try cancellation.CancellationTokenSource.init(std.testing.allocator);
    defer source.deinit();
    const token = try source.token();

    picker.show();
    try provide(impl, options, &picker, token);
    try std.testing.expectEqualStrings("a", picker.activeItem().?.id);

    try picker.setValue("x");
    try refresh(impl, options, &picker);
    try std.testing.expectEqualStrings("x", state.filter[0..state.filter_len]);

    try picker.setValue("none");
    try refresh(impl, options, &picker);
    try std.testing.expectEqualStrings("No matching results", picker.activeItem().?.label);

    try picker.setValue("a");
    try refresh(impl, options, &picker);
    picker.accept();
    try accept(&picker);
    try std.testing.expectEqual(@as(usize, 1), state.accepted);
    try std.testing.expect(state.hidden_first);
}
