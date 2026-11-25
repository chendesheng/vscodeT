// Port of the Unix subset of
// `src/vs/platform/terminal/node/terminalProfiles.ts`.
//
// Reads `/etc/shells`, names profiles by basename, de-duplicates repeated
// basenames the way upstream does, and picks the configured or system default
// shell. Windows profile discovery (PowerShell/WSL/Cmder) is not ported: the
// terminal host reports the platform as unsupported.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const terminal = @import("../common/terminal.zig");
const profiles_common = @import("../common/terminalProfiles.zig");

pub const Profiles = struct {
    arena: std.heap.ArenaAllocator,
    items: []terminal.ITerminalProfile,
    default_index: ?usize,

    pub fn deinit(self: *Profiles) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn defaultProfile(self: *const Profiles) ?*const terminal.ITerminalProfile {
        const index = self.default_index orelse return null;
        return &self.items[index];
    }

    pub fn find(self: *const Profiles, name: []const u8) ?*const terminal.ITerminalProfile {
        for (self.items) |*profile| {
            if (std.mem.eql(u8, profile.profile_name, name)) {
                return profile;
            }
        }
        return null;
    }
};

pub const DetectOptions = struct {
    include_detected: bool = true,
    /// `terminal.integrated.defaultProfile.<os>`.
    default_profile_name: ?[]const u8 = null,
    /// The `SHELL` environment value.
    shell_env: ?[]const u8 = null,
    /// Test hook: replaces the contents of `/etc/shells`.
    shells_contents: ?[]const u8 = null,
};

pub fn detectUnixProfiles(
    allocator: Allocator,
    io: Io,
    options: DetectOptions,
) !Profiles {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var contents: []const u8 = "";
    if (options.include_detected) {
        if (options.shells_contents) |value| {
            contents = value;
        } else if (std.Io.Dir.cwd().readFileAlloc(io, "/etc/shells", arena_alloc, .limited(256 * 1024))) |value| {
            contents = value;
        } else |_| {
            contents = "/bin/sh\n";
        }
    }

    var paths: std.array_list.Managed([]const u8) = .init(arena_alloc);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = blk: {
            const comment = std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len;
            break :blk std.mem.trim(u8, raw_line[0..comment], " \t\r");
        };
        if (line.len == 0) continue;
        if (!std.fs.path.isAbsolute(line)) continue;
        try paths.append(line);
    }

    const items = try arena_alloc.alloc(terminal.ITerminalProfile, paths.items.len);
    var name_counts: std.StringHashMapUnmanaged(usize) = .empty;
    var default_index: ?usize = null;
    for (paths.items, 0..) |path, index| {
        const base = profiles_common.shellName(path);
        const entry = try name_counts.getOrPut(arena_alloc, base);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
        const count = entry.value_ptr.*;
        const name = if (count > 1)
            try std.fmt.allocPrint(arena_alloc, "{s} ({d})", .{ base, count })
        else
            base;
        const owned_name = try arena_alloc.dupe(u8, name);
        const owned_path = try arena_alloc.dupe(u8, path);
        const is_default = if (options.default_profile_name) |wanted|
            std.mem.eql(u8, wanted, owned_name)
        else
            false;
        if (is_default) default_index = index;
        items[index] = .{
            .profile_name = owned_name,
            .path = owned_path,
            .args = defaultArgs(path),
            .is_default = is_default,
            .is_auto_detected = true,
        };
    }

    if (default_index == null) {
        if (options.shell_env) |shell| {
            for (items, 0..) |profile, index| {
                if (std.mem.eql(u8, profile.path, shell)) {
                    default_index = index;
                    break;
                }
            }
        }
    }
    if (default_index == null) {
        const preferred = switch (terminal.currentOperatingSystem()) {
            .macintosh => "/bin/zsh",
            .linux => "/bin/bash",
            else => "/bin/sh",
        };
        for (items, 0..) |profile, index| {
            if (std.mem.eql(u8, profile.path, preferred)) {
                default_index = index;
                break;
            }
        }
    }
    if (default_index == null and items.len > 0) default_index = 0;
    if (default_index) |index| items[index].is_default = true;

    return .{
        .arena = arena,
        .items = items,
        .default_index = default_index,
    };
}

/// macOS launches zsh/bash as a login shell by default; upstream's fallback
/// profile does the same.
pub fn defaultArgs(path: []const u8) []const []const u8 {
    if (terminal.is_macintosh) {
        const name = profiles_common.shellName(path);
        if (std.mem.eql(u8, name, "zsh") or std.mem.eql(u8, name, "bash")) {
            return &macos_login_args;
        }
    }
    return &.{};
}

const macos_login_args = [_][]const u8{"--login"};

/// Resolves a profile for a direct shell path (the `SHELL` fallback when
/// `/etc/shells` is unreadable).
pub fn profileForPath(
    arena: Allocator,
    path: []const u8,
    profile_name: ?[]const u8,
) !terminal.ITerminalProfile {
    const name = profile_name orelse profiles_common.shellName(path);
    return .{
        .profile_name = try arena.dupe(u8, name),
        .path = try arena.dupe(u8, path),
        .args = defaultArgs(path),
        .is_auto_detected = true,
        .is_default = true,
    };
}

/// Locate a terminal helper in an absolute PATH entry. The working directory
/// may be the opened workspace, so relative executable search paths are skipped.
pub fn findTerminalExecutable(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !?[]u8 {
    const search_path = std.c.getenv("PATH") orelse return null;
    var paths = std.mem.tokenizeScalar(u8, std.mem.span(search_path), std.fs.path.delimiter);
    while (paths.next()) |directory| {
        if (!std.fs.path.isAbsolute(directory)) continue;
        const executable = try std.fs.path.join(allocator, &.{ directory, name });
        std.Io.Dir.accessAbsolute(io, executable, .{ .execute = true }) catch {
            allocator.free(executable);
            continue;
        };
        return executable;
    }
    return null;
}
