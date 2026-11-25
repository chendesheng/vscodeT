// Port of SwitchCompositeViewAction from
// src/vs/workbench/browser/parts/compositeBarActions.ts.
const std = @import("std");
const ServicesAccessor = @import("../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const service = @import("../../services/panecomposite/browser/panecomposite.zig");
const Location = @import("../../common/views.zig").ViewContainerLocation;

pub const SwitchCompositeViewAction = struct {
    pub fn run(accessor: ServicesAccessor, location: Location, offset: isize) !void {
        const panes = try accessor.get(service.pane_composite_part_service_id);
        const active = panes.getActivePaneComposite(location) orelse return;
        // IDs borrow their part; only the temporary array is allocated.
        const allocator = panes.allocator;
        const visible = try panes.getVisiblePaneCompositeIds(location, allocator);
        defer allocator.free(visible);
        for (visible, 0..) |id, index| {
            if (!std.mem.eql(u8, id, active.id)) continue;
            const len: isize = @intCast(visible.len);
            const next: usize = @intCast(@mod(@as(isize, @intCast(index)) + len + offset, len));
            _ = try panes.openPaneComposite(visible[next], location, true);
            break;
        }
    }
};
