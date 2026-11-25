// Port of the terminal-supported list commands in
// src/vs/workbench/browser/actions/listCommands.ts. The existing palette
// metadata is retained while the actual target follows IListService.
const actions = @import("../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const lists = @import("../../../platform/list/browser/listService.zig");

fn listAction(comptime id: []const u8, title: []const u8, comptime operation: lists.Navigation) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title, .category = "List" },
        .f1 = true,
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                const service = try accessor.get(lists.list_service_id);
                const widget = service.lastFocusedList() orelse return;
                try widget.run(widget.context, operation);
            }
        }.run,
    };
}

pub const list_actions = [_]actions.Action2{
    listAction("list.focusUp", "Focus Previous Item", .focus_previous),
    listAction("list.focusDown", "Focus Next Item", .focus_next),
    listAction("list.focusFirst", "Focus First Item", .focus_first),
    listAction("list.focusLast", "Focus Last Item", .focus_last),
    listAction("list.focusPageUp", "Focus Previous Page", .focus_previous_page),
    listAction("list.focusPageDown", "Focus Next Page", .focus_next_page),
    listAction("list.collapse", "Collapse", .collapse),
    listAction("list.expand", "Expand", .expand),
    listAction("list.toggleExpand", "Toggle Expand", .toggle_expand),
    listAction("list.select", "Select", .select),
};
