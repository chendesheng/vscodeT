// Runtime enable/disable commands for the built-in Vim extension.
const std = @import("std");
const ui = @import("ui");
const Workbench = @import("../../../../browser/workbench.zig").Workbench;
const VimRuntime = @import("../../browser/vimRuntime.zig").VimRuntime;
const time_compat = @import("../../../../../base/common/timeCompat.zig");

test "Vim runtime: enable/disable persist and control the key handler" {
    const allocator = std.testing.allocator;
    const io = time_compat.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "vim.txt", .data = "hello\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{}\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const relative_len = try tmp.dir.realPathFile(io, "vim.txt", &path_buffer);
    const relative = path_buffer[0..relative_len];
    var settings_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const settings_len = try tmp.dir.realPathFile(io, "settings.json", &settings_buffer);
    const settings_path = settings_buffer[0..settings_len];

    var workbench = try Workbench.init(allocator, io, &.{relative}, 80, 24);
    defer workbench.deinit();
    try workbench.setUserSettingsPaths(&.{settings_path});
    const runtime = try VimRuntime.init(allocator, workbench);
    defer runtime.deinit();

    try std.testing.expect(workbench.commands.get("vim.enable") != null);
    try std.testing.expect(workbench.commands.get("vim.disable") != null);
    try std.testing.expect(workbench.commands.get("vim.toggle") == null);
    try std.testing.expect(!runtime.isEnabled());

    try workbench.commands.execute("vim.enable");
    try std.testing.expect(runtime.isEnabled());
    try std.testing.expect(workbench.configuration.?.getBool("vim.enabled", false));
    const insert = ui.KeyEvent{ .key = .{ .char = 'i' } };
    try std.testing.expect(runtime.host.?.dispatchKey(&insert));

    try workbench.commands.execute("vim.disable");
    try std.testing.expect(!runtime.isEnabled());
    try std.testing.expect(!workbench.configuration.?.getBool("vim.enabled", true));
    try std.testing.expect(runtime.host == null);

    const persisted = try tmp.dir.readFile(io, "settings.json", &settings_buffer);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "\"vim.enabled\":false") != null);
}
