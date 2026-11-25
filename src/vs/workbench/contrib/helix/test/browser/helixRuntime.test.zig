// Runtime enable/disable commands for the built-in Helix extension.

const std = @import("std");
const ui = @import("ui");
const HelixRuntime = @import("../../browser/helixRuntime.zig").HelixRuntime;
const VimRuntime = @import("../../../vim/browser/vimRuntime.zig").VimRuntime;
const time_compat = @import("../../../../../base/common/timeCompat.zig");

fn disableHelix(context: *anyopaque) void {
    const helix: *HelixRuntime = @ptrCast(@alignCast(context));
    if (helix.isEnabled()) helix.setEnabledPersistent(false) catch {};
}

fn disableVim(context: *anyopaque) void {
    const vim: *VimRuntime = @ptrCast(@alignCast(context));
    if (vim.isEnabled()) vim.setEnabledPersistent(false) catch {};
}

pub fn Tests(comptime factory: anytype) type {
    return struct {
        const TestWindow = @import("../../../../test/browser/workbenchTestServices.zig").TestWindow(factory);
        test "Helix runtime: enable/disable persist and control the key handler" {
            const allocator = std.testing.allocator;
            const io = time_compat.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "helix.txt", .data = "hello\n" });
            try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{}\n" });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const relative_len = try tmp.dir.realPathFile(io, "helix.txt", &path_buffer);
            const relative = path_buffer[0..relative_len];
            var settings_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const settings_len = try tmp.dir.realPathFile(io, "settings.json", &settings_buffer);
            const settings_path = settings_buffer[0..settings_len];

            const workbench_window = try TestWindow.init(allocator, io, &.{relative}, 80, 24);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();
            try workbench.setUserSettingsPaths(&.{settings_path});
            const runtime = try HelixRuntime.init(allocator, workbench.builtin_host);
            defer runtime.deinit();

            try std.testing.expect(workbench.commands.get("helix.enable") != null);
            try std.testing.expect(workbench.commands.get("helix.disable") != null);
            try std.testing.expect(workbench.commands.get("helix.toggle") == null);
            try std.testing.expect(!runtime.isEnabled());

            try workbench.commands.execute("helix.enable");
            try std.testing.expect(runtime.isEnabled());
            try std.testing.expect(workbench.configuration.?.getBool("helix.enabled", false));
            const insert = ui.KeyEvent{ .key = .{ .char = 'i' } };
            try std.testing.expect(runtime.host.?.dispatchKey(&insert));

            try workbench.commands.execute("helix.disable");
            try std.testing.expect(!runtime.isEnabled());
            try std.testing.expect(!workbench.configuration.?.getBool("helix.enabled", true));
            try std.testing.expect(runtime.host == null);

            const persisted = try tmp.dir.readFile(io, "settings.json", &settings_buffer);
            try std.testing.expect(std.mem.indexOf(u8, persisted, "\"helix.enabled\":false") != null);
        }

        test "Helix runtime: enabling Helix disables and persists Vim off" {
            const allocator = std.testing.allocator;
            const io = time_compat.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "helix.txt", .data = "hello\n" });
            try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{}\n" });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const relative_len = try tmp.dir.realPathFile(io, "helix.txt", &path_buffer);
            const relative = path_buffer[0..relative_len];
            var settings_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const settings_len = try tmp.dir.realPathFile(io, "settings.json", &settings_buffer);
            const settings_path = settings_buffer[0..settings_len];

            const workbench_window = try TestWindow.init(allocator, io, &.{relative}, 80, 24);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();
            try workbench.setUserSettingsPaths(&.{settings_path});

            const vim = try VimRuntime.init(allocator, workbench.builtin_host);
            defer vim.deinit();
            const helix = try HelixRuntime.init(allocator, workbench.builtin_host);
            defer helix.deinit();
            vim.setOnEnable(.{ .context = helix, .on_enable = disableHelix });
            helix.setOnEnable(.{ .context = vim, .on_enable = disableVim });

            try workbench.commands.execute("vim.enable");
            try std.testing.expect(vim.isEnabled());
            try std.testing.expect(!helix.isEnabled());

            try workbench.commands.execute("helix.enable");
            try std.testing.expect(helix.isEnabled());
            try std.testing.expect(!vim.isEnabled());
            try std.testing.expect(!workbench.configuration.?.getBool("vim.enabled", true));

            try workbench.commands.execute("vim.enable");
            try std.testing.expect(vim.isEnabled());
            try std.testing.expect(!helix.isEnabled());
            try std.testing.expect(!workbench.configuration.?.getBool("helix.enabled", true));
        }
    };
}
