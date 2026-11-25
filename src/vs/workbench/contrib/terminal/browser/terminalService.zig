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

const Tab = @import("../../../browser/parts/editor/editorPane.zig").Tab;
const EditorViewFactory = @import("../../../browser/parts/editor/editorPane.zig").EditorViewFactory;
const GroupView = @import("../../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("../../../browser/parts/editor/editorPart.zig").EditorPart(GroupView);
const GroupDirection = @import("../../../services/editor/common/editorGroupsService.zig").GroupDirection;

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

    pub fn createEditor(self: *TerminalService, factory: EditorViewFactory, pane: *GroupView, parent: ?*TerminalInstance) !*Tab {
        const instance = try self.createInstance(parent);
        errdefer instance.deinit();
        return self.editor.openEditor(self.allocator, self.io, factory, pane, instance);
    }

    pub fn createEditorWithProfile(self: *TerminalService, factory: EditorViewFactory, pane: *GroupView, profile: terminal.ITerminalProfile, rename: bool) !*Tab {
        const instance = try self.createInstanceWithProfile(profile);
        errdefer instance.deinit();
        if (rename) try instance.rename(profile.profile_name);
        return self.editor.openEditor(self.allocator, self.io, factory, pane, instance);
    }

    pub fn createEditorToSide(self: *TerminalService, factory: EditorViewFactory, part: *EditorPart, direction: GroupDirection, parent: ?*TerminalInstance) !*Tab {
        const source = part.activeView() orelse return error.GroupPaneMissing;
        if (try part.findGroup(.{ .direction = direction }, source, false)) |target| {
            return self.createEditor(factory, target, parent);
        }
        const pane = try part.splitGroup(source, if (direction == .DOWN) .vertical else .horizontal, false);
        errdefer _ = part.removeView(pane);
        return self.createEditor(factory, pane, parent);
    }

    /// Transfer the resource without disposing its PTY. Open before detach
    /// so allocation failure cannot orphan the panel instance.
    pub fn moveToEditor(self: *TerminalService, factory: EditorViewFactory, pane: *GroupView, index: usize) !void {
        const instance = self.at(index) orelse return;
        _ = try self.editor.openEditor(self.allocator, self.io, factory, pane, instance);
        _ = self.group.detach(index);
    }

    pub fn moveToTerminalView(self: *TerminalService, pane: *GroupView, tab: *Tab, host: GroupView.CloseHost) !void {
        const input = tab.terminal_input orelse return;
        try self.group.instances.ensureUnusedCapacity(1);
        try self.editor.instances.ensureUnusedCapacity(1);
        const instance = input.detachInstance();
        host.close_tab(host.context, pane, tab) catch |err| {
            // A close can report an allocation failure after removing the tab.
            if (host.is_alive(host.context, pane, tab)) {
                input.registerInstance(&self.editor);
                return err;
            }
            try self.group.add(instance);
            return err;
        };
        try self.group.add(instance);
    }

    pub fn splitSelectedTabs(self: *TerminalService, index: usize) !void {
        if (!(self.at(index) orelse return).tab_selected) return self.split(index);
        var source = self.count();
        while (source > 0) {
            source -= 1;
            if (self.at(source).?.tab_selected) try self.split(source);
        }
        self.group.clearTabSelection();
    }

    pub fn killSelectedTabs(self: *TerminalService, index: usize) void {
        if (!(self.at(index) orelse return).tab_selected) return self.kill(index);
        var source = self.count();
        while (source > 0) {
            source -= 1;
            if (self.at(source).?.tab_selected) self.kill(source);
        }
    }

    pub fn joinSelectedTabs(self: *TerminalService) !void {
        var selected: std.ArrayList(*TerminalInstance) = .empty;
        defer selected.deinit(self.allocator);
        for (self.group.instances.items) |instance| {
            if (instance.tab_selected) try selected.append(self.allocator, instance);
        }
        try self.group.joinInstances(selected.items);
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

    /// Focus comes from the host's active-part and group events, not from a
    /// terminal paint pass. Returns whether mouse capture must be cleared.
    pub fn setFocusedInstance(self: *TerminalService, focused_instance: ?*TerminalInstance) bool {
        var changed = false;
        for (0..self.instanceCount()) |index| {
            const instance = self.instanceAt(index).?;
            changed = instance.setFocused(instance == focused_instance) or changed;
        }
        return changed;
    }

    pub fn getInstanceFromId(self: *const TerminalService, id: usize) ?*TerminalInstance {
        for (0..self.instanceCount()) |index| {
            const instance = self.instanceAt(index).?;
            if (instance.id == id) return instance;
        }
        return null;
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
