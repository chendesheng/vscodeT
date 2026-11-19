// Port of the Unix-relevant cases of
// `src/vs/platform/terminal/test/node/terminalProfiles.test.ts` and
// `src/vs/platform/terminal/test/common/terminalProfiles.test.ts`.

const std = @import("std");
const profiles = @import("../../node/terminalProfiles.zig");
const common = @import("../../common/terminalProfiles.zig");

test "terminalProfiles: reads /etc/shells style content and de-duplicates names" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var detected = try profiles.detectUnixProfiles(allocator, io, .{
        .shells_contents =
        \\# comment
        \\/bin/bash
        \\/bin/zsh
        \\/usr/local/bin/bash
        \\/bin/bash
        \\/opt/homebrew/bin/fish
        \\relative/path
        \\
        ,
        .shell_env = "/bin/zsh",
    });
    defer detected.deinit();

    try std.testing.expectEqual(@as(usize, 5), detected.items.len);
    try std.testing.expectEqualStrings("bash", detected.items[0].profile_name);
    try std.testing.expectEqualStrings("zsh", detected.items[1].profile_name);
    try std.testing.expectEqualStrings("bash (2)", detected.items[2].profile_name);
    try std.testing.expectEqualStrings("bash (3)", detected.items[3].profile_name);
    try std.testing.expectEqualStrings("fish", detected.items[4].profile_name);
    try std.testing.expectEqualStrings("/bin/zsh", detected.defaultProfile().?.path);
}

test "terminalProfiles: configured default name wins over SHELL" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var detected = try profiles.detectUnixProfiles(allocator, io, .{
        .shells_contents = "/bin/bash\n/bin/zsh\n",
        .default_profile_name = "zsh",
        .shell_env = "/bin/bash",
    });
    defer detected.deinit();
    try std.testing.expectEqualStrings("zsh", detected.defaultProfile().?.profile_name);
    try std.testing.expect(detected.defaultProfile().?.is_default);
}

test "terminalProfiles: shell type mapping" {
    try std.testing.expectEqual(
        @import("../../common/terminal.zig").TerminalShellType{ .posix = .fish },
        common.shellType("/opt/homebrew/bin/fish"),
    );
}
