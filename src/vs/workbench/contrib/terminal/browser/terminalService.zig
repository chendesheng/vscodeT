// Port of the panel-location subset of
// `src/vs/workbench/contrib/terminal/browser/terminalService.ts` and
// `terminalGroupService.ts`.
//
// The service resolves profiles and owns the panel and editor instance hosts.
// Remote terminals are outside the local PTY host.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const terminal = @import("../../../../platform/terminal/common/terminal.zig");
const profiles_mod = @import("../../../../platform/terminal/node/terminalProfiles.zig");
const profiles_common = @import("../../../../platform/terminal/common/terminalProfiles.zig");
const pty = @import("../../../../platform/terminal/node/pty.zig");
const emulator = @import("./terminalEmulator.zig");
const instance_mod = @import("./terminalInstance.zig");
const group_mod = @import("./terminalGroup.zig");
const TerminalEditorService = @import("./terminalEditorService.zig").TerminalEditorService;
const ui = @import("ui");
const configuration_mod = @import("../common/terminalConfiguration.zig");
const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;

pub const TerminalInstance = instance_mod.TerminalInstance;
pub const TerminalGroup = group_mod.TerminalGroup;

pub const Options = struct {
    workspace_root: ?[]const u8 = null,
    configuration: ?*ConfigurationService = null,
    colors: emulator.Colors = .{},
    multi_root: bool = false,
    /// Test seam: replaces the process/env/cwd resolution.
    launch: ?*const fn (*TerminalService, Allocator) anyerror!*TerminalInstance = null,
};

pub const TerminalService = struct {
    allocator: Allocator,
    io: Io,
    options: Options,
    config: configuration_mod.Config,
    config_arena: std.heap.ArenaAllocator,
    profiles: profiles_mod.Profiles,
    group: TerminalGroup,
    editor: TerminalEditorService,
    next_id: usize = 1,

    pub fn init(allocator: Allocator, io: Io, options: Options) !*TerminalService {
        const self = try allocator.create(TerminalService);
        errdefer allocator.destroy(self);
        const shell_env = shellFromEnvironment();
        var config_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer config_arena.deinit();
        const config = try cloneConfig(config_arena.allocator(), configuration_mod.Config.load(options.configuration));
        var profiles = try profiles_mod.detectUnixProfiles(allocator, io, .{
            .default_profile_name = config.default_profile_name,
            .shell_env = shell_env,
        });
        errdefer profiles.deinit();
        self.* = .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .config = config,
            .config_arena = config_arena,
            .profiles = profiles,
            .group = TerminalGroup.init(allocator),
            .editor = TerminalEditorService.init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *TerminalService) void {
        self.group.deinit();
        self.editor.deinit();
        self.profiles.deinit();
        self.config_arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn count(self: *const TerminalService) usize {
        return self.group.count();
    }

    pub fn active(self: *const TerminalService) ?*TerminalInstance {
        return self.group.activeInstance();
    }

    pub fn at(self: *const TerminalService, index: usize) ?*TerminalInstance {
        return self.group.at(index);
    }

    pub fn create(self: *TerminalService) !*TerminalInstance {
        const instance = try self.createInstance(null);
        errdefer instance.deinit();
        try self.group.add(instance);
        return instance;
    }

    pub fn split(self: *TerminalService, index: usize) !void {
        const parent = self.at(index) orelse return;
        const instance = try self.createInstance(parent);
        errdefer instance.deinit();
        try self.group.split(index, instance);
    }

    pub fn createWithProfile(self: *TerminalService, profile: terminal.ITerminalProfile) !*TerminalInstance {
        const instance = try self.createInstanceWithProfile(profile);
        errdefer instance.deinit();
        try self.group.add(instance);
        return instance;
    }

    pub fn createInstanceWithProfile(self: *TerminalService, profile: terminal.ITerminalProfile) !*TerminalInstance {
        return self.launchInstance(null, &profile, null);
    }

    pub fn createInstance(self: *TerminalService, parent: ?*TerminalInstance) !*TerminalInstance {
        return self.launchInstance(parent, self.profiles.defaultProfile(), null);
    }

    pub fn createForTask(self: *TerminalService, profile: terminal.ITerminalProfile, cwd: ?[]const u8) !*TerminalInstance {
        const instance = try self.launchInstance(null, &profile, cwd);
        errdefer instance.deinit();
        try instance.rename(profile.profile_name);
        try self.group.add(instance);
        return instance;
    }

    fn launchInstance(self: *TerminalService, parent: ?*TerminalInstance, profile: ?*const terminal.ITerminalProfile, requested_cwd: ?[]const u8) !*TerminalInstance {
        if (self.options.launch) |launch| return launch(self, self.allocator);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        const shell = if (profile) |value| value.path else shellFromEnvironment() orelse "/bin/sh";
        const args = if (profile) |value| value.args else &.{};
        const process_name = profiles_common.shellName(shell);
        const profile_name = if (profile) |value| value.profile_name else process_name;
        const split_cwd = if (parent) |instance| switch (configuration_mod.Config.load(self.options.configuration).split_cwd) {
            .workspaceRoot => self.options.workspace_root,
            .initial => instance.initial_cwd,
            .inherited => instance.cwd orelse instance.initial_cwd,
        } else null;
        const cwd = requested_cwd orelse split_cwd orelse try resolveCwd(scratch, self.options.workspace_root, self.config.cwd);
        const env = try self.buildEnvironment(scratch);

        const instance = try TerminalInstance.create(self.allocator, self.io, self.next_id, .{
            .shell = shell,
            .args = args,
            .cwd = cwd,
            .env = env,
            .inherit_env = self.config.inherit_env,
            .scrollback_lines = self.config.scrollback,
            .colors = self.options.colors,
            .profile_name = profile_name,
            .workspace_folder = self.options.workspace_root,
            .title_template = self.config.title,
            .description_template = self.config.description,
            .separator = self.config.separator,
            .multi_root = self.options.multi_root,
        });
        self.next_id += 1;
        return instance;
    }

    pub fn killActive(self: *TerminalService) void {
        if (self.group.count() == 0) return;
        self.group.remove(self.group.active);
    }

    pub fn kill(self: *TerminalService, index: usize) void {
        self.group.remove(index);
    }

    pub fn next(self: *TerminalService) void {
        self.group.next();
    }

    pub fn previous(self: *TerminalService) void {
        self.group.previous();
    }

    pub fn setActive(self: *TerminalService, index: usize) bool {
        return self.group.setActive(index);
    }

    pub fn layout(self: *TerminalService, content: ui.Rect) void {
        for (self.group.instances.items, 0..) |instance, index| {
            const rect = self.group.paneRect(content, index);
            const cols: u16 = @intCast(@min(ui.cell.snap(rect.w), std.math.maxInt(u16)));
            const rows: u16 = @intCast(@min(ui.cell.snap(rect.h), std.math.maxInt(u16)));
            if (cols > 0 and rows > 0) instance.layout(cols, rows);
        }
    }

    pub fn instanceCount(self: *const TerminalService) usize {
        return self.count() + self.editor.instances.items.len;
    }

    pub fn instanceAt(self: *const TerminalService, index: usize) ?*TerminalInstance {
        if (index < self.count()) return self.at(index);
        const editor_index = index - self.count();
        if (editor_index >= self.editor.instances.items.len) return null;
        return self.editor.instances.items[editor_index];
    }

    /// Reaps instances whose PTY closed, then drains their pending output
    /// before the workbench removes them from their host.
    pub fn pollExits(self: *TerminalService) bool {
        var changed = false;
        for (0..self.instanceCount()) |index| {
            const instance = self.instanceAt(index).?;
            if (instance.exit == null) {
                if (instance.process.pollExit()) |result| {
                    _ = instance.feedOutput() catch {
                        instance.exit = result;
                        instance.process_state = .killed_by_process;
                        instance.process.closeMaster();
                    };
                    changed = true;
                }
            }
        }
        return changed;
    }

    fn buildEnvironment(self: *TerminalService, scratch: Allocator) ![]pty.EnvVar {
        var env: std.array_list.Managed(pty.EnvVar) = .init(scratch);
        try env.append(.{ .key = "TERM", .value = "xterm-256color" });
        try env.append(.{ .key = "COLORTERM", .value = "truecolor" });
        try env.append(.{ .key = "TERM_PROGRAM", .value = "vscode" });
        try env.append(.{ .key = "TERM_PROGRAM_VERSION", .value = "1.147.0" });
        if (self.options.configuration) |configuration| {
            const section = terminal.envSettingId(terminal.currentOperatingSystem());
            if (configuration.getValue(section, .{})) |value| {
                if (value.* == .object) {
                    var it = value.object.iterator();
                    while (it.next()) |entry| {
                        switch (entry.value_ptr.*) {
                            .string => |text| try env.append(.{
                                .key = entry.key_ptr.*,
                                .value = text,
                            }),
                            .null => try env.append(.{
                                .key = entry.key_ptr.*,
                                .value = null,
                            }),
                            else => {},
                        }
                    }
                }
            }
        }
        return env.toOwnedSlice();
    }
};

fn cloneConfig(arena: Allocator, config: configuration_mod.Config) !configuration_mod.Config {
    var result = config;
    result.title = try arena.dupe(u8, config.title);
    result.description = try arena.dupe(u8, config.description);
    result.separator = try arena.dupe(u8, config.separator);
    result.cursor_style = try arena.dupe(u8, config.cursor_style);
    result.cursor_style_inactive = try arena.dupe(u8, config.cursor_style_inactive);
    result.default_location = try arena.dupe(u8, config.default_location);
    if (config.cwd) |cwd| result.cwd = try arena.dupe(u8, cwd);
    if (config.default_profile_name) |name| result.default_profile_name = try arena.dupe(u8, name);
    return result;
}

fn resolveCwd(allocator: Allocator, workspace_root: ?[]const u8, configured: ?[]const u8) !?[]u8 {
    if (configured) |value| {
        if (std.fs.path.isAbsolute(value)) return try allocator.dupe(u8, value);
        if (workspace_root) |root| return try std.fs.path.join(allocator, &.{ root, value });
    }
    if (workspace_root) |root| return try allocator.dupe(u8, root);
    return null;
}

fn shellFromEnvironment() ?[]const u8 {
    const raw = std.c.getenv("SHELL") orelse return null;
    return std.mem.span(raw);
}

test "TerminalService: configured cwd resolution" {
    const allocator = std.testing.allocator;
    const absolute = try resolveCwd(allocator, "/workspace", "/tmp");
    defer allocator.free(absolute.?);
    try std.testing.expectEqualStrings("/tmp", absolute.?);

    const relative = try resolveCwd(allocator, "/workspace", "sub");
    defer allocator.free(relative.?);
    const expected_relative = try std.fs.path.join(allocator, &.{ "/workspace", "sub" });
    defer allocator.free(expected_relative);
    try std.testing.expectEqualStrings(expected_relative, relative.?);

    const fallback = try resolveCwd(allocator, "/workspace", null);
    defer allocator.free(fallback.?);
    try std.testing.expectEqualStrings("/workspace", fallback.?);
}
