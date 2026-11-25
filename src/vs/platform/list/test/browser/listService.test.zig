// Tests of the port of ListService in src/vs/platform/list/browser/listService.ts.
const std = @import("std");
const mod = @import("../../browser/listService.zig");

test "ListService remembers last focused list across blur and forgets disposed widget" {
    var service = mod.ListService.init(std.testing.allocator);
    defer service.deinit();
    var first = mod.ListFocus.init(std.testing.allocator);
    defer first.deinit();
    var second = mod.ListFocus.init(std.testing.allocator);
    const noop = struct {
        fn run(_: *anyopaque, _: mod.Navigation) !void {}
    }.run;
    try service.register(.{ .context = &first, .focus = &first, .run = noop });
    try service.register(.{ .context = &second, .focus = &second, .run = noop });
    try std.testing.expect(service.lastFocusedList() == null);
    first.setFocused(true);
    first.setFocused(false);
    try std.testing.expect(service.lastFocusedList().?.focus == &first);
    second.setFocused(true);
    try std.testing.expect(service.lastFocusedList().?.focus == &second);
    second.deinit();
    try std.testing.expect(service.lastFocusedList() == null);
}
