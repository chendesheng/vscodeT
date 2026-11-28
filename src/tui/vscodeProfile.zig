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
//! (`MINECODE_PORTABLE`), `VSCODE_APPDATA`, `--user-data-dir`, then the
//! platform application-data directory. Minecode uses product-specific names
//! for the portable and extensions overrides to avoid sharing VS Code's data.
//!
//! The VS Code base profile is the stable VS Code location on the host. It has
//! no environment override, matching the fact that VS Code itself has no
//! environment variable for "read another profile".

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const platform = @import("../vs/base/common/platform.zig");
const environment_service = @import("../vs/platform/environment/common/environmentService.zig");

/// The terminal product's data-folder name, the counterpart of VS Code's
/// `Code` folder under the platform application-data directory.
pub const product_data_folder = "minecode";
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
    /// Minecode counterpart of upstream portable mode (`MINECODE_PORTABLE`).
    env_portable: ?[]const u8 = null,
    /// Upstream `VSCODE_APPDATA`.
    env_appdata: ?[]const u8 = null,
    /// Minecode extension-directory override (`MINECODE_EXTENSIONS`).
    env_extensions: ?[]const u8 = null,
    /// Upstream `--user-data-dir`.
    cli_user_data_dir: ?[]const u8 = null,
    /// Upstream `--extensions-dir`.
    cli_extensions_dir: ?[]const u8 = null,
    /// Upstream `--logsPath`.
    cli_logs_path: ?[]const u8 = null,

    /// Reads the terminal process environment. Portable and extensions paths
    /// use Minecode's own variables; the caller supplies the parsed CLI values.
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
            .env_portable = environ.get("MINECODE_PORTABLE"),
            .env_appdata = environ.get("VSCODE_APPDATA"),
            .env_extensions = environ.get("MINECODE_EXTENSIONS"),
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
    /// Upstream `extensionsPath` (CLI, `MINECODE_EXTENSIONS`, portable, home).
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

/// Port of `getDefaultUserDataPath` + `MINECODE_PORTABLE`/`VSCODE_APPDATA`/
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

/// Test roots are spelled the way the host spells an absolute path. The
/// `Environment.os` field still selects the layout branch under test, but path
/// construction uses the host separator, matching production `std.fs.path`.
fn native(posix: []const u8, windows_path: []const u8) []const u8 {
    return if (builtin.os.tag == .windows) windows_path else posix;
}

fn expectPath(allocator: Allocator, parts: []const []const u8, actual: []const u8) !void {
    const expected = try std.fs.path.join(allocator, parts);
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, actual);
}

test "vscodeProfile: macOS defaults use Code/User and the TUI user data folder" {
    const allocator = std.testing.allocator;
    const home = native("/Users/me", "C:\\Users\\me");
    var profile = try discover(allocator, .{
        .os = .Macintosh,
        .home = home,
    });
    defer profile.deinit();

    try expectPath(allocator, &.{ home, "Library", "Application Support", "Code", "User" }, profile.vscode_user_dir.?);
    try expectPath(
        allocator,
        &.{ home, "Library", "Application Support", "minecode" },
        profile.user_data_dir.?,
    );
    try std.testing.expectEqual(@as(usize, 2), profile.settings_paths.len);
    try expectPath(
        allocator,
        &.{ home, "Library", "Application Support", "Code", "User", "settings.json" },
        profile.settings_paths[0],
    );
    try expectPath(
        allocator,
        &.{ home, "Library", "Application Support", "minecode", "User", "settings.json" },
        profile.tuiSettingsPath().?,
    );
    try expectPath(
        allocator,
        &.{ home, "Library", "Application Support", "minecode", "User", "keybindings.json" },
        profile.tuiKeybindingsPath().?,
    );
    try expectPath(allocator, &.{ home, ".minecode", "extensions" }, profile.extensions_dir.?);
    try expectPath(
        allocator,
        &.{ home, "Library", "Application Support", "minecode", "logs" },
        profile.logs_dir.?,
    );
}

test "vscodeProfile: Linux honours XDG_CONFIG_HOME" {
    const allocator = std.testing.allocator;
    const home = native("/home/me", "C:\\Users\\me");
    const xdg = native("/home/me/.config-custom", "C:\\Users\\me\\.config-custom");
    var profile = try discover(allocator, .{
        .os = .Linux,
        .home = home,
        .xdg_config_home = xdg,
    });
    defer profile.deinit();

    try expectPath(
        allocator,
        &.{ xdg, "Code", "User", "settings.json" },
        profile.settings_paths[0],
    );
    try expectPath(
        allocator,
        &.{ xdg, "minecode", "User", "keybindings.json" },
        profile.tuiKeybindingsPath().?,
    );
    try expectPath(allocator, &.{ home, ".minecode", "extensions" }, profile.extensions_dir.?);
}

test "vscodeProfile: Windows uses APPDATA and USERPROFILE extensions" {
    const allocator = std.testing.allocator;
    const appdata = "C:\\Users\\me\\AppData\\Roaming";
    var profile = try discover(allocator, .{
        .os = .Windows,
        .home = "C:\\Users\\me",
        .appdata = appdata,
    });
    defer profile.deinit();

    try expectPath(allocator, &.{ appdata, "Code", "User", "settings.json" }, profile.settings_paths[0]);
    try expectPath(
        allocator,
        &.{ appdata, "minecode", "User", "settings.json" },
        profile.tuiSettingsPath().?,
    );
    try expectPath(allocator, &.{ "C:\\Users\\me", ".minecode", "extensions" }, profile.extensions_dir.?);
}

test "vscodeProfile: only Minecode extensions and portable environment variables are read" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("VSCODE_EXTENSIONS", "/vscode/extensions");
    try environ.put("VSCODE_PORTABLE", "/vscode/portable");
    const old = Environment.fromProcess(&environ);
    try std.testing.expect(old.env_extensions == null);
    try std.testing.expect(old.env_portable == null);

    try environ.put("MINECODE_EXTENSIONS", "/minecode/extensions");
    try environ.put("MINECODE_PORTABLE", "/minecode/portable");
    const current = Environment.fromProcess(&environ);
    try std.testing.expectEqualStrings("/minecode/extensions", current.env_extensions.?);
    try std.testing.expectEqualStrings("/minecode/portable", current.env_portable.?);
}

test "vscodeProfile: Minecode portable and appdata variables win" {
    const allocator = std.testing.allocator;
    const portable_root = native("/portable", "C:\\portable");
    var portable = try discover(allocator, .{
        .os = .Macintosh,
        .home = native("/Users/me", "C:\\Users\\me"),
        .env_portable = portable_root,
        .cli_user_data_dir = native("/ignored", "C:\\ignored"),
    });
    defer portable.deinit();
    try expectPath(allocator, &.{ portable_root, "user-data" }, portable.user_data_dir.?);
    try expectPath(
        allocator,
        &.{ portable_root, "user-data", "User", "settings.json" },
        portable.tuiSettingsPath().?,
    );
    try expectPath(allocator, &.{ portable_root, "extensions" }, portable.extensions_dir.?);

    const appdata_root = native("/var/appdata", "C:\\var\\appdata");
    var appdata = try discover(allocator, .{
        .os = .Linux,
        .home = native("/home/me", "C:\\Users\\me"),
        .env_appdata = appdata_root,
    });
    defer appdata.deinit();
    try expectPath(allocator, &.{ appdata_root, "minecode" }, appdata.user_data_dir.?);
}

test "vscodeProfile: --user-data-dir resolves against VSCODE_CWD" {
    const allocator = std.testing.allocator;
    const cwd = native("/work", "C:\\work");
    const custom_exts = native("/custom-exts", "C:\\custom-exts");
    var profile = try discover(allocator, .{
        .os = .Linux,
        .home = native("/home/me", "C:\\Users\\me"),
        .cwd = cwd,
        .cli_user_data_dir = "profile-data",
        .cli_extensions_dir = custom_exts,
        .cli_logs_path = "logs",
    });
    defer profile.deinit();

    try expectPath(allocator, &.{ cwd, "profile-data" }, profile.user_data_dir.?);
    try expectPath(
        allocator,
        &.{ cwd, "profile-data", "User", "settings.json" },
        profile.tuiSettingsPath().?,
    );
    try std.testing.expectEqualStrings(custom_exts, profile.extensions_dir.?);
    try expectPath(allocator, &.{ cwd, "logs" }, profile.logs_dir.?);
}

test "vscodeProfile: no home still yields explicit user-data-dir paths only" {
    const allocator = std.testing.allocator;
    var empty = try discover(allocator, .{ .os = .Linux });
    defer empty.deinit();
    try std.testing.expect(empty.vscode_user_dir == null);
    try std.testing.expect(empty.user_data_dir == null);
    try std.testing.expect(empty.extensions_dir == null);
    try std.testing.expectEqual(@as(usize, 0), empty.settings_paths.len);

    const explicit_dir = native("/data/tui", "C:\\data\\tui");
    var explicit = try discover(allocator, .{
        .os = .Linux,
        .cli_user_data_dir = explicit_dir,
    });
    defer explicit.deinit();
    try std.testing.expectEqualStrings(explicit_dir, explicit.user_data_dir.?);
    try std.testing.expectEqual(@as(usize, 1), explicit.settings_paths.len);
    try expectPath(allocator, &.{ explicit_dir, "User", "settings.json" }, explicit.tuiSettingsPath().?);
}
