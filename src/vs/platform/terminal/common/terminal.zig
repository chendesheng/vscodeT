// Port of the portable subset of `src/vs/platform/terminal/common/terminal.ts`.
//
// The TUI has one local PTY backend, so the pty-host protocol, remote
// terminals, detached terminals, task/extension terminal providers and the
// serialized process details are not part of this slice. The profile, shell
// launch, location and process-state shapes below are kept close to upstream
// because the workbench instance/service and the title label computer consume
// them.

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;
pub const is_macintosh = builtin.os.tag == .macos;
pub const is_linux = builtin.os.tag == .linux;

pub const OperatingSystem = enum { windows, macintosh, linux, unknown };

pub fn currentOperatingSystem() OperatingSystem {
    return switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .macintosh,
        .linux => .linux,
        else => .unknown,
    };
}

/// Shell families the environment/path helpers care about. The enum values are
/// the upstream names without the TS enum noise.
pub const PosixShellType = enum {
    bash,
    sh,
    zsh,
    fish,
};

pub const WindowsShellType = enum {
    git_bash,
};

pub const GeneralShellType = enum {
    power_shell,
};

pub const TerminalShellType = union(enum) {
    posix: PosixShellType,
    windows: WindowsShellType,
    general: GeneralShellType,
    unknown,
};

pub const TerminalLocation = enum { panel, editor };

pub const TerminalLocationConfigValue = enum {
    editor,
    view,
    panel,
};

pub const ProcessState = enum {
    uninitialized,
    launching,
    launch_failed,
    running,
    killed_during_launch,
    killed_by_user,
    killed_by_process,
};

/// Where a terminal's title came from. Mirrors upstream `TitleEventSource`.
pub const TitleEventSource = enum {
    api,
    process,
    sequence,
    config,
};

pub const ITerminalEnvironment = struct {
    /// `null` removes the key from the inherited environment.
    vars: std.StringHashMapUnmanaged(?[]const u8) = .empty,

    pub fn init() ITerminalEnvironment {
        return .{};
    }

    pub fn deinit(self: *ITerminalEnvironment, allocator: std.mem.Allocator) void {
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |value| allocator.free(value);
        }
        self.vars.deinit(allocator);
    }

    pub fn put(
        self: *ITerminalEnvironment,
        allocator: std.mem.Allocator,
        key: []const u8,
        value: ?[]const u8,
    ) !void {
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = if (value) |v| try allocator.dupe(u8, v) else null;
        errdefer if (owned_value) |v| allocator.free(v);
        const result = try self.vars.getOrPut(allocator, owned_key);
        if (result.found_existing) {
            allocator.free(owned_key);
            if (result.value_ptr.*) |old| allocator.free(old);
        }
        result.value_ptr.* = owned_value;
    }
};

pub const ITerminalProfile = struct {
    profile_name: []const u8,
    path: []const u8,
    args: []const []const u8 = &.{},
    /// Owned by the profile when `owns_strings` is true.
    env: ?*const ITerminalEnvironment = null,
    is_default: bool = false,
    is_auto_detected: bool = false,
    override_name: bool = false,
    is_from_path: bool = false,
    owns_strings: bool = false,
};

pub const IShellLaunchConfig = struct {
    name: ?[]const u8 = null,
    executable: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    env: ?*const ITerminalEnvironment = null,
    /// `true` for a task terminal (`${task}` in labels).
    is_task: bool = false,
    /// `true` for a local terminal (`${local}` in labels).
    is_local: bool = true,
    /// The profile this config was resolved from, when any.
    profile_name: ?[]const u8 = null,
};

pub const TerminalSettingPrefix = struct {
    pub const automation_profile = "terminal.integrated.automationProfile.";
    pub const default_profile = "terminal.integrated.defaultProfile.";
    pub const profiles = "terminal.integrated.profiles.";
};

/// The settings this port reads. IDs match upstream exactly.
pub const TerminalSettingId = struct {
    pub const default_profile_linux = "terminal.integrated.defaultProfile.linux";
    pub const default_profile_macos = "terminal.integrated.defaultProfile.osx";
    pub const default_profile_windows = "terminal.integrated.defaultProfile.windows";
    pub const profiles_linux = "terminal.integrated.profiles.linux";
    pub const profiles_macos = "terminal.integrated.profiles.osx";
    pub const profiles_windows = "terminal.integrated.profiles.windows";
    pub const cwd = "terminal.integrated.cwd";
    pub const env_linux = "terminal.integrated.env.linux";
    pub const env_macos = "terminal.integrated.env.osx";
    pub const env_windows = "terminal.integrated.env.windows";
    pub const inherit_env = "terminal.integrated.inheritEnv";
    pub const scrollback = "terminal.integrated.scrollback";
    pub const cursor_style = "terminal.integrated.cursorStyle";
    pub const cursor_style_inactive = "terminal.integrated.cursorStyleInactive";
    pub const cursor_blinking = "terminal.integrated.cursorBlinking";
    pub const terminal_title = "terminal.integrated.tabs.title";
    pub const terminal_description = "terminal.integrated.tabs.description";
    pub const terminal_title_separator = "terminal.integrated.tabs.separator";
    pub const tabs_hide_condition = "terminal.integrated.tabs.hideCondition";
    pub const default_location = "terminal.integrated.defaultLocation";
    pub const enable_bell = "terminal.integrated.enableBell";
    pub const enable_visual_bell = "terminal.integrated.enableVisualBell";
    pub const hide_on_last_closed = "terminal.integrated.hideOnLastClosed";
    pub const shell_integration_enabled = "terminal.integrated.shellIntegration.enabled";
};

pub fn defaultProfileSettingId(os: OperatingSystem) []const u8 {
    return switch (os) {
        .windows => TerminalSettingId.default_profile_windows,
        .macintosh => TerminalSettingId.default_profile_macos,
        else => TerminalSettingId.default_profile_linux,
    };
}

pub fn envSettingId(os: OperatingSystem) []const u8 {
    return switch (os) {
        .windows => TerminalSettingId.env_windows,
        .macintosh => TerminalSettingId.env_macos,
        else => TerminalSettingId.env_linux,
    };
}

pub fn profilesSettingId(os: OperatingSystem) []const u8 {
    return switch (os) {
        .windows => TerminalSettingId.profiles_windows,
        .macintosh => TerminalSettingId.profiles_macos,
        else => TerminalSettingId.profiles_linux,
    };
}

test "terminal: default setting ids follow the platform" {
    try std.testing.expectEqualStrings(
        "terminal.integrated.defaultProfile.osx",
        defaultProfileSettingId(.macintosh),
    );
    try std.testing.expectEqualStrings(
        "terminal.integrated.env.linux",
        envSettingId(.linux),
    );
}
