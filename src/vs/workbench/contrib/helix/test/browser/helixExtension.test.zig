// Built-in Helix extension integration tests.
const std = @import("std");
const ui = @import("ui");
const Workbench = @import("../../../../browser/workbench.zig").Workbench;
const BuiltinExtensionHost = @import("../../../../api/browser/builtinExtensionHost.zig").BuiltinExtensionHost;
const helix_extension = @import("../../browser/helixExtension.zig");
const time_compat = @import("../../../../../base/common/timeCompat.zig");

test "Helix extension: registers a key handler and edits through the host" {
    const allocator = std.testing.allocator;
    const io = time_compat.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "helix.txt", .data = "hello\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const relative_len = try tmp.dir.realPathFile(io, "helix.txt", &path_buffer);
    const relative = path_buffer[0..relative_len];

    var workbench = try Workbench.init(allocator, io, &.{relative}, 80, 24);
    defer workbench.deinit();

    var host = try BuiltinExtensionHost.init(allocator, workbench);
    defer host.deinit();
    try host.registerBuiltin(try helix_extension.create(allocator));
    host.activate();

    const insert = ui.KeyEvent{ .key = .{ .char = 'i' } };
    try std.testing.expect(host.dispatchKey(&insert));
    const text = ui.KeyEvent{ .key = .{ .text = "abc" } };
    try std.testing.expect(host.dispatchKey(&text));
    const escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(host.dispatchKey(&escape));

    var value = try workbench.activeTab().?.editor.model.getValue(.LF, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("abchello\n", value.items);

    const undo = ui.KeyEvent{ .key = .{ .char = 'u' } };
    try std.testing.expect(host.dispatchKey(&undo));
    var undone = try workbench.activeTab().?.editor.model.getValue(.LF, false);
    defer undone.deinit();
    try std.testing.expectEqualStrings("hello\n", undone.items);
}

test "Helix extension: deactivation removes its key handler" {
    const allocator = std.testing.allocator;
    const io = time_compat.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "helix.txt", .data = "hello\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const relative_len = try tmp.dir.realPathFile(io, "helix.txt", &path_buffer);
    const relative = path_buffer[0..relative_len];

    var workbench = try Workbench.init(allocator, io, &.{relative}, 80, 24);
    defer workbench.deinit();

    var host = try BuiltinExtensionHost.init(allocator, workbench);
    defer host.deinit();
    try host.registerBuiltin(try helix_extension.create(allocator));
    host.activate();
    host.extensions.deactivateAll();

    const insert = ui.KeyEvent{ .key = .{ .char = 'i' } };
    try std.testing.expect(!host.dispatchKey(&insert));
}

test "Helix extension: helix.enabled is read from user settings" {
    const allocator = std.testing.allocator;
    const io = time_compat.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "helix.txt", .data = "hello\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{\"helix.enabled\": true}" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const relative_len = try tmp.dir.realPathFile(io, "helix.txt", &path_buffer);
    const relative = path_buffer[0..relative_len];
    var settings_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const settings_len = try tmp.dir.realPathFile(io, "settings.json", &settings_buffer);
    const settings_path = settings_buffer[0..settings_len];

    var workbench = try Workbench.init(allocator, io, &.{relative}, 80, 24);
    defer workbench.deinit();
    try std.testing.expect(!(workbench.configuration orelse return error.MissingConfiguration).getBool("helix.enabled", false));
    try workbench.setUserSettingsPaths(&.{settings_path});
    try std.testing.expect((workbench.configuration orelse return error.MissingConfiguration).getBool("helix.enabled", false));
}

test "Helix extension: read-only edits report an error and do not crash" {
    const allocator = std.testing.allocator;
    const io = time_compat.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "helix.txt", .data = "hello\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const relative_len = try tmp.dir.realPathFile(io, "helix.txt", &path_buffer);
    const relative = path_buffer[0..relative_len];

    var workbench = try Workbench.init(allocator, io, &.{relative}, 80, 24);
    defer workbench.deinit();

    var host = try BuiltinExtensionHost.init(allocator, workbench);
    defer host.deinit();
    try host.registerBuiltin(try helix_extension.create(allocator));
    host.activate();

    const editor = workbench.activeTab().?.editor;
    editor.setReadOnly(true);
    const delete = ui.KeyEvent{ .key = .{ .char = 'd' } };
    try std.testing.expect(!host.dispatchKey(&delete));
    try std.testing.expect(std.mem.startsWith(u8, editor.message(), "Helix:"));

    var value = try editor.model.getValue(.LF, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("hello\n", value.items);
}
