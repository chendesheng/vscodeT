//! VS Code profile discovery for the terminal workbench.
//!
//! The TUI treats the user's VS Code profile as its base configuration and
//! layers the terminal's own profile on top. Both profiles follow upstream
//! VS Code's layout:
//!
//!   VS Code base profile:  <Code user data dir>/User/settings.json
//!                          <Code user data dir>/User/keybindings.json
//!   TUI profile:           <TUI user data dir>/User/settings.json
//!                          <TUI user data dir>/User/keybindings.json
//!   extensions:            <extensions dir>   (upstream `extensionsPath`)
//!   logs:                  <TUI user data dir>/logs
//!
//! The TUI user data dir ports `getUserDataPath` from
//! `src/vs/platform/environment/node/userDataPath.ts`: portable mode
//! (`VSCODE_PORTABLE`), `VSCODE_APPDATA`, `--user-data-dir`, then the
//! platform application-data directory. There is no TUI-specific environment
//! variable; every override is an upstream CLI switch or environment variable.
//!
//! The VS Code base profile is the stable VS Code location on the host. It has
//! no environment override, matching the fact that VS Code itself has no
//! environment variable for "read another profile".

const std = @import("std");
const Allocator = std.mem.Allocator;
const platform = @import("../vs/base/common/platform.zig");
const environment_service = @import("../vs/platform/environment/common/environmentService.zig");

/// The terminal product's data-folder name, the counterpart of VS Code's
/// `Code` folder under the platform application-data directory.
pub const product_data_folder = "vscode-textbuffer";
/// The stable VS Code data-folder name whose `User` profile is the base layer.
pub const vscode_data_folder = "Code";

/// Inputs of discovery. The app builds this from the process environment and
/// the parsed CLI; tests construct it directly so every OS layout is covered.
pub const Environment = struct {
    os: platform.OperatingSystem = platform.OS,
    home: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    /// Windows `%APPDATA%`.
    appdata: ?[]const u8 = null,
    /// Windows `%USERPROFILE%` fallback when `%APPDATA%` is absent.
    userprofile: ?[]const u8 = null,
    /// Upstream `VSCODE_CWD`, used to resolve a relative `--user-data-dir`.
    cwd: ?[]const u8 = null,
    /// Upstream `VSCODE_PORTABLE`.
    env_portable: ?[]const u8 = null,
    /// Upstream `VSCODE_APPDATA`.
    env_appdata: ?[]const u8 = null,
    /// Upstream `VSCODE_EXTENSIONS`.
    env_extensions: ?[]const u8 = null,
    /// Upstream `--user-data-dir`.
    cli_user_data_dir: ?[]const u8 = null,
    /// Upstream `--extensions-dir`.
    cli_extensions_dir: ?[]const u8 = null,
    /// Upstream `--logsPath`.
    cli_logs_path: ?[]const u8 = null,

    /// Reads the terminal process environment. Only upstream variables are
    /// consulted; the CLI values are filled by the caller from parsed args.
    pub fn fromProcess(environ: *const std.process.Environ.Map) Environment {
        const windows = platform.OS == .Windows;
        return .{
            .os = platform.OS,
            // Upstream's `os.homedir()` uses USERPROFILE on Windows and HOME
            // elsewhere for the extensions fallback.
            .home = if (windows)
                environ.get("USERPROFILE") orelse environ.get("HOME")
            else
                environ.get("HOME") orelse environ.get("USERPROFILE"),
            .xdg_config_home = environ.get("XDG_CONFIG_HOME"),
            .appdata = environ.get("APPDATA"),
            .userprofile = environ.get("USERPROFILE"),
            .cwd = environ.get("VSCODE_CWD"),
            .env_portable = environ.get("VSCODE_PORTABLE"),
            .env_appdata = environ.get("VSCODE_APPDATA"),
            .env_extensions = environ.get("VSCODE_EXTENSIONS"),
        };
    }
};

pub const Profile = struct {
    allocator: Allocator,
    /// The stable VS Code `User` directory used as the base settings layer.
    vscode_user_dir: ?[]u8 = null,
    /// The terminal's upstream-style user data directory.
    user_data_dir: ?[]u8 = null,
    settings_paths: []const []const u8 = &.{},
    keybindings_paths: []const []const u8 = &.{},
    /// Upstream `extensionsPath` (CLI, `VSCODE_EXTENSIONS`, portable, home).
    extensions_dir: ?[]u8 = null,
    logs_dir: ?[]u8 = null,

    pub fn deinit(self: *Profile) void {
        if (self.vscode_user_dir) |path| self.allocator.free(path);
        if (self.user_data_dir) |path| self.allocator.free(path);
        freePaths(self.allocator, self.settings_paths);
        freePaths(self.allocator, self.keybindings_paths);
        if (self.extensions_dir) |path| self.allocator.free(path);
        if (self.logs_dir) |path| self.allocator.free(path);
        self.* = .{ .allocator = self.allocator };
    }

    /// The file the "Open User Settings (JSON)" command edits: the TUI layer.
    pub fn tuiSettingsPath(self: *const Profile) ?[]const u8 {
        if (self.settings_paths.len == 0) return null;
        return self.settings_paths[self.settings_paths.len - 1];
    }

    /// The file the "Open Keyboard Shortcuts (JSON)" command edits.
    pub fn tuiKeybindingsPath(self: *const Profile) ?[]const u8 {
        if (self.keybindings_paths.len == 0) return null;
        return self.keybindings_paths[self.keybindings_paths.len - 1];
    }

    /// The terminal's `main.log`, using the upstream `logsPath` directory.
    pub fn mainLogPath(self: *const Profile, allocator: Allocator) !?[]u8 {
        const logs = self.logs_dir orelse return null;
        return try std.fs.path.join(allocator, &.{ logs, "main.log" });
    }
};

pub fn discover(allocator: Allocator, env: Environment) !Profile {
    var profile = Profile{ .allocator = allocator };
    errdefer profile.deinit();

    profile.vscode_user_dir = try vscodeUserDir(allocator, env);
    profile.user_data_dir = try userDataDir(allocator, env);

    var settings_paths = std.array_list.Managed([]const u8).init(allocator);
    errdefer freePathList(allocator, &settings_paths);
    var keybindings_paths = std.array_list.Managed([]const u8).init(allocator);
    errdefer freePathList(allocator, &keybindings_paths);

    if (profile.vscode_user_dir) |dir| {
        try settings_paths.append(try std.fs.path.join(allocator, &.{ dir, "settings.json" }));
        try keybindings_paths.append(try std.fs.path.join(allocator, &.{ dir, "keybindings.json" }));
    }
    if (profile.user_data_dir) |dir| {
        try settings_paths.append(try std.fs.path.join(allocator, &.{ dir, "User", "settings.json" }));
        try keybindings_paths.append(try std.fs.path.join(allocator, &.{ dir, "User", "keybindings.json" }));
    }

    profile.settings_paths = try settings_paths.toOwnedSlice();
    profile.keybindings_paths = try keybindings_paths.toOwnedSlice();

    if (env.home != null or env.cli_extensions_dir != null or env.env_extensions != null or env.env_portable != null) {
        // `extensionsPath` ports the CLI/env/portable precedence upstream uses.
        // An explicit CLI/env root works even when no home directory exists.
        const environment = environment_service.Environment{
            .user_home = env.home orelse "",
            .cli_extensions_dir = env.cli_extensions_dir,
            .env_extensions = env.env_extensions,
            .env_portable = env.env_portable,
        };
        profile.extensions_dir = try environment.extensionsPath(allocator);
    }

    if (env.cli_logs_path) |path| {
        profile.logs_dir = try resolvePath(allocator, env.cwd, path);
    } else if (profile.user_data_dir) |dir| {
        profile.logs_dir = try std.fs.path.join(allocator, &.{ dir, "logs" });
    }

    return profile;
}

/// Port of `getDefaultUserDataPath` + `VSCODE_PORTABLE`/`VSCODE_APPDATA`/
/// `--user-data-dir` precedence from upstream `userDataPath.ts`.
fn userDataDir(allocator: Allocator, env: Environment) !?[]u8 {
    if (env.env_portable) |portable| {
        return try std.fs.path.join(allocator, &.{ portable, "user-data" });
    }
    if (env.env_appdata) |root| {
        return try std.fs.path.join(allocator, &.{ root, product_data_folder });
    }
    if (env.cli_user_data_dir) |dir| {
        return try resolvePath(allocator, env.cwd, dir);
    }
    const app_data = try platformAppData(allocator, env) orelse return null;
    defer allocator.free(app_data);
    return try std.fs.path.join(allocator, &.{ app_data, product_data_folder });
}

/// The stable VS Code `User` directory. Unlike the TUI profile this has no
/// override: upstream has no environment variable for reading another profile.
fn vscodeUserDir(allocator: Allocator, env: Environment) !?[]u8 {
    const app_data = try platformAppData(allocator, env) orelse return null;
    defer allocator.free(app_data);
    return try std.fs.path.join(allocator, &.{ app_data, vscode_data_folder, "User" });
}

fn platformAppData(allocator: Allocator, env: Environment) !?[]u8 {
    switch (env.os) {
        .Macintosh => {
            const home = env.home orelse return null;
            return try std.fs.path.join(allocator, &.{ home, "Library", "Application Support" });
        },
        .Windows => {
            if (env.appdata) |dir| return try allocator.dupe(u8, dir);
            const profile_dir = env.userprofile orelse env.home orelse return null;
            return try std.fs.path.join(allocator, &.{ profile_dir, "AppData", "Roaming" });
        },
        .Linux => {
            if (env.xdg_config_home) |dir| return try allocator.dupe(u8, dir);
            const home = env.home orelse return null;
            return try std.fs.path.join(allocator, &.{ home, ".config" });
        },
    }
}

fn resolvePath(allocator: Allocator, cwd: ?[]const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    if (cwd) |base| return std.fs.path.resolve(allocator, &.{ base, path });
    return std.fs.path.resolve(allocator, &.{path});
}

fn freePaths(allocator: Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    if (paths.len > 0) allocator.free(paths);
}

fn freePathList(allocator: Allocator, paths: *std.array_list.Managed([]const u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit();
}

test "vscodeProfile: macOS defaults use Code/User and the TUI user data folder" {
    const allocator = std.testing.allocator;
    var profile = try discover(allocator, .{
        .os = .Macintosh,
        .home = "/Users/me",
    });
    defer profile.deinit();

    try std.testing.expectEqualStrings(
        "/Users/me/Library/Application Support/Code/User",
        profile.vscode_user_dir.?,
    );
    try std.testing.expectEqualStrings(
        "/Users/me/Library/Application Support/vscode-textbuffer",
        profile.user_data_dir.?,
    );
    try std.testing.expectEqual(@as(usize, 2), profile.settings_paths.len);
    try std.testing.expectEqualStrings(
        "/Users/me/Library/Application Support/Code/User/settings.json",
        profile.settings_paths[0],
    );
    try std.testing.expectEqualStrings(
        "/Users/me/Library/Application Support/vscode-textbuffer/User/settings.json",
        profile.tuiSettingsPath().?,
    );
    try std.testing.expectEqualStrings(
        "/Users/me/Library/Application Support/vscode-textbuffer/User/keybindings.json",
        profile.tuiKeybindingsPath().?,
    );
    try std.testing.expectEqualStrings(
        "/Users/me/.vscode/extensions",
        profile.extensions_dir.?,
    );
    try std.testing.expectEqualStrings(
        "/Users/me/Library/Application Support/vscode-textbuffer/logs",
        profile.logs_dir.?,
    );
}

test "vscodeProfile: Linux honours XDG_CONFIG_HOME" {
    const allocator = std.testing.allocator;
    var profile = try discover(allocator, .{
        .os = .Linux,
        .home = "/home/me",
        .xdg_config_home = "/home/me/.config-custom",
    });
    defer profile.deinit();

    try std.testing.expectEqualStrings(
        "/home/me/.config-custom/Code/User/settings.json",
        profile.settings_paths[0],
    );
    try std.testing.expectEqualStrings(
        "/home/me/.config-custom/vscode-textbuffer/User/keybindings.json",
        profile.tuiKeybindingsPath().?,
    );
}

test "vscodeProfile: Windows uses APPDATA and USERPROFILE extensions" {
    const allocator = std.testing.allocator;
    var profile = try discover(allocator, .{
        .os = .Windows,
        .home = "C:\\Users\\me",
        .appdata = "C:\\Users\\me\\AppData\\Roaming",
    });
    defer profile.deinit();

    const expected = try std.fs.path.join(allocator, &.{ "C:\\Users\\me\\AppData\\Roaming", "Code", "User", "settings.json" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, profile.settings_paths[0]);
    const tui_expected = try std.fs.path.join(allocator, &.{ "C:\\Users\\me\\AppData\\Roaming", "vscode-textbuffer", "User", "settings.json" });
    defer allocator.free(tui_expected);
    try std.testing.expectEqualStrings(tui_expected, profile.tuiSettingsPath().?);
}

test "vscodeProfile: upstream portable and appdata variables win" {
    const allocator = std.testing.allocator;
    var portable = try discover(allocator, .{
        .os = .Macintosh,
        .home = "/Users/me",
        .env_portable = "/portable",
        .cli_user_data_dir = "/ignored",
    });
    defer portable.deinit();
    try std.testing.expectEqualStrings("/portable/user-data", portable.user_data_dir.?);
    try std.testing.expectEqualStrings(
        "/portable/user-data/User/settings.json",
        portable.tuiSettingsPath().?,
    );
    try std.testing.expectEqualStrings("/portable/extensions", portable.extensions_dir.?);

    var appdata = try discover(allocator, .{
        .os = .Linux,
        .home = "/home/me",
        .env_appdata = "/var/appdata",
    });
    defer appdata.deinit();
    try std.testing.expectEqualStrings("/var/appdata/vscode-textbuffer", appdata.user_data_dir.?);
}

test "vscodeProfile: --user-data-dir resolves against VSCODE_CWD" {
    const allocator = std.testing.allocator;
    var profile = try discover(allocator, .{
        .os = .Linux,
        .home = "/home/me",
        .cwd = "/work",
        .cli_user_data_dir = "profile-data",
        .cli_extensions_dir = "/custom-exts",
        .cli_logs_path = "logs",
    });
    defer profile.deinit();

    try std.testing.expectEqualStrings("/work/profile-data", profile.user_data_dir.?);
    try std.testing.expectEqualStrings(
        "/work/profile-data/User/settings.json",
        profile.tuiSettingsPath().?,
    );
    try std.testing.expectEqualStrings("/custom-exts", profile.extensions_dir.?);
    try std.testing.expectEqualStrings("/work/logs", profile.logs_dir.?);
}

test "vscodeProfile: no home still yields explicit user-data-dir paths only" {
    const allocator = std.testing.allocator;
    var empty = try discover(allocator, .{ .os = .Linux });
    defer empty.deinit();
    try std.testing.expect(empty.vscode_user_dir == null);
    try std.testing.expect(empty.user_data_dir == null);
    try std.testing.expect(empty.extensions_dir == null);
    try std.testing.expectEqual(@as(usize, 0), empty.settings_paths.len);

    var explicit = try discover(allocator, .{
        .os = .Linux,
        .cli_user_data_dir = "/data/tui",
    });
    defer explicit.deinit();
    try std.testing.expectEqualStrings("/data/tui", explicit.user_data_dir.?);
    try std.testing.expectEqual(@as(usize, 1), explicit.settings_paths.len);
    try std.testing.expectEqualStrings("/data/tui/User/settings.json", explicit.tuiSettingsPath().?);
}
