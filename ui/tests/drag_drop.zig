const std = @import("std");
const ui = @import("ui");
const input = ui.event;
const Kind = ui.drag_drop.Kind;
const DragSession = ui.drag_drop.DragSession;

test "drag and drop follows the release target and ends exactly once" {
    const Session = DragSession(u8, usize, void);
    const Host = struct {
        events: std.ArrayList(Kind) = .empty,
        dropped: ?usize = null,
        pub fn dragTarget(_: *@This(), _: u8, mouse: input.MouseEvent) ?usize {
            return mouse.y;
        }
        pub fn dispatchDrag(self: *@This(), event: *Session.Event) void {
            self.events.append(std.testing.allocator, event.kind) catch unreachable;
            if (event.kind == .dragover and event.target.? != 4) {
                event.preventDefault();
                event.data_transfer.drop_effect = .move;
            }
            if (event.kind == .drop) self.dropped = event.target;
        }
    };
    var host: Host = .{};
    defer host.events.deinit(std.testing.allocator);
    var session: Session = .{};
    const press: input.MouseEvent = .{ .kind = .down, .button = .left, .x = 8, .y = 1 };
    session.arm(1, press);
    try std.testing.expect(!session.handleMouse(&host, .{ .kind = .move, .button = .left, .x = 7, .y = 1 }));
    try std.testing.expect(session.handleMouse(&host, .{ .kind = .move, .button = .left, .x = 5, .y = 1 }));
    try std.testing.expect(session.handleMouse(&host, .{ .kind = .up, .button = .left, .x = 5, .y = 2 }));
    session.cancel(&host);
    try std.testing.expectEqual(@as(?usize, 2), host.dropped);
    try std.testing.expectEqualSlices(Kind, &.{ .dragstart, .drag, .dragenter, .dragover, .drag, .dragenter, .dragleave, .dragover, .drop, .dragend }, host.events.items);

    host.events.clearRetainingCapacity();
    host.dropped = null;
    session.arm(1, press);
    _ = session.handleMouse(&host, .{ .kind = .move, .button = .left, .x = 5, .y = 4 });
    _ = session.handleMouse(&host, .{ .kind = .up, .button = .left, .x = 5, .y = 4 });
    try std.testing.expectEqual(@as(?usize, null), host.dropped);
    try std.testing.expectEqual(Kind.dragleave, host.events.items[host.events.items.len - 2]);
    try std.testing.expectEqual(Kind.dragend, host.events.items[host.events.items.len - 1]);

    host.events.clearRetainingCapacity();
    session.arm(1, press);
    _ = session.handleMouse(&host, .{ .kind = .move, .button = .left, .x = 5, .y = 1 });
    session.cancel(&host);
    try std.testing.expectEqual(Kind.dragend, host.events.items[host.events.items.len - 1]);
    try std.testing.expect(session.source == null and session.data_transfer.image == null);
}
