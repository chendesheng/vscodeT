// Port of the portable state machine of
// `src/vs/workbench/contrib/terminal/browser/terminalInstance.ts`.
//
// The browser instance is dominated by xterm.js/DOM wiring. This slice keeps
// the lifecycle, title/sequence/cwd state, renderer hand-off and exit state.
// The xterm.js replacement is `terminalEmulator.zig`, and the pty host is
// `src/vs/platform/terminal/node/pty.zig`.
//
// `TerminalLabelComputer` below is a close port of the upstream class; the
// templating tests are ported in `test/browser/terminalInstance.test.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const terminal = @import("../../../../platform/terminal/common/terminal.zig");
const pty = @import("../../../../platform/terminal/node/pty.zig");
const emulator_mod = @import("./terminalEmulator.zig");

pub const TerminalEmulator = emulator_mod.TerminalEmulator;
pub const ProcessState = terminal.ProcessState;

/// Port of `TerminalInstance.Constants` in `terminalInstance.ts`. These are the
/// no-container fallback dimensions (`_initDimensions`); the view always lays
/// the instance out with its measured cells as soon as the container exists.
pub const Constants = struct {
    pub const DefaultCols: u16 = 80;
    pub const DefaultRows: u16 = 30;
};

pub const Options = struct {
    shell: []const u8,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    env: []const pty.EnvVar = &.{},
    inherit_env: bool = true,
    /// Fallback dimensions until `layout` receives the view's cell size.
    cols: u16 = Constants.DefaultCols,
    rows: u16 = Constants.DefaultRows,
    scrollback_lines: usize = 1000,
    colors: emulator_mod.Colors = .{},
    profile_name: []const u8 = "shell",
    workspace_folder: ?[]const u8 = null,
    title_template: []const u8 = "${process}",
    description_template: []const u8 = "${task}${separator}${local}${separator}${cwdFolder}",
    separator: []const u8 = " - ",
    multi_root: bool = false,
};

const CompletionShell = enum { bash, zsh, fish, pwsh };

pub const TerminalInstance = struct {
    allocator: Allocator,
    id: usize,
    /// Panel groups have contiguous entries in the terminal tab list.
    panel_group_id: usize = 0,
    panel_group_active: bool = false,
    split_weight: f64 = 1,
    tab_selected: bool = false,
    view_focused: bool = false,
    process: pty.PtyProcess,
    emulator: TerminalEmulator,
    process_state: ProcessState = .running,
    exit: ?pty.Exit = null,
    cols: u16,
    rows: u16,
    /// Title sequence reported through OSC 0/2, if any.
    sequence: ?[]u8 = null,
    /// Current working directory reported through OSC 7, if any.
    cwd: ?[]u8 = null,
    initial_cwd: ?[]u8 = null,
    workspace_folder: ?[]u8 = null,
    shell_type: ?CompletionShell = null,
    process_name: []u8,
    profile_name: []u8,
    static_title: ?[]u8 = null,
    bell_pending: bool = false,
    title_error: bool = false,
    labels: TerminalLabelComputer = undefined,

    pub fn create(allocator: Allocator, io: Io, id: usize, options: Options) !*TerminalInstance {
        const self = try allocator.create(TerminalInstance);
        errdefer allocator.destroy(self);

        var process = try pty.PtyProcess.spawn(allocator, .{
            .executable = options.shell,
            .args = options.args,
            .cwd = options.cwd,
            .env = options.env,
            .inherit_env = options.inherit_env,
            .cols = options.cols,
            .rows = options.rows,
        });
        errdefer process.deinit();

        self.* = .{
            .allocator = allocator,
            .id = id,
            .process = process,
            .emulator = undefined,
            .cols = options.cols,
            .rows = options.rows,
            .process_name = try allocator.dupe(u8, options.profile_name),
            .profile_name = try allocator.dupe(u8, options.profile_name),
            .initial_cwd = if (options.cwd) |cwd| try allocator.dupe(u8, cwd) else null,
            .workspace_folder = if (options.workspace_folder) |folder| try allocator.dupe(u8, folder) else null,
        };
        errdefer {
            allocator.free(self.process_name);
            allocator.free(self.profile_name);
            if (self.initial_cwd) |value| allocator.free(value);
            if (self.workspace_folder) |value| allocator.free(value);
        }
        self.shell_type = std.meta.stringToEnum(CompletionShell, std.fs.path.stem(options.shell));
        self.labels = try TerminalLabelComputer.init(allocator);
        self.labels.title_template = options.title_template;
        self.labels.description_template = options.description_template;
        self.labels.separator = options.separator;
        self.labels.multi_root = options.multi_root;
        errdefer self.labels.deinit(allocator);

        self.refreshLabel();

        try self.emulator.init(allocator, io, .{
            .cols = options.cols,
            .rows = options.rows,
            .scrollback_lines = options.scrollback_lines,
            .colors = options.colors,
            .host = .{
                .context = self,
                .write_pty = hostWrite,
                .bell = hostBell,
                .title_changed = hostTitle,
                .pwd_changed = hostPwd,
                .reset = hostReset,
                .render_hold = hostHold,
            },
        });
        return self;
    }

    pub fn deinit(self: *TerminalInstance) void {
        self.emulator.deinit();
        self.process.deinit();
        self.labels.deinit(self.allocator);
        self.freeStrings();
        self.allocator.destroy(self);
    }

    fn freeStrings(self: *TerminalInstance) void {
        if (self.sequence) |value| self.allocator.free(value);
        if (self.cwd) |value| self.allocator.free(value);
        if (self.initial_cwd) |value| self.allocator.free(value);
        if (self.workspace_folder) |value| self.allocator.free(value);
        if (self.static_title) |value| self.allocator.free(value);
        self.allocator.free(self.process_name);
        self.allocator.free(self.profile_name);
    }

    pub fn fd(self: *const TerminalInstance) ?std.posix.fd_t {
        return self.process.fd();
    }

    pub fn feedOutput(self: *TerminalInstance) !bool {
        var buffer: [65536]u8 = undefined;
        var got = false;
        while (true) {
            const n = try self.process.read(&buffer);
            if (n == 0) break;
            self.emulator.feed(buffer[0..n]);
            got = true;
        }
        if (self.process.pollExit()) |result| {
            self.exit = result;
            self.process_state = .killed_by_process;
            self.process.closeMaster();
        }
        return got;
    }

    pub fn writeInput(self: *TerminalInstance, bytes: []const u8) void {
        self.process.write(bytes) catch {
            self.title_error = true;
        };
    }

    pub fn flushInput(self: *TerminalInstance) void {
        self.process.flush() catch {};
    }

    pub fn hasPendingWrite(self: *const TerminalInstance) bool {
        return self.process.hasPendingWrite();
    }

    pub fn resize(self: *TerminalInstance, cols: u16, rows: u16) !void {
        self.cols = @max(cols, 1);
        self.rows = @max(rows, 1);
        try self.emulator.resize(self.cols, self.rows);
        try self.process.resize(self.cols, self.rows);
    }

    /// Port of `TerminalInstance.layout`: apply the view's dimensions to the
    /// emulator and the pty. The browser method converts a DOM pixel dimension
    /// with `getXtermScaledDimensions`; the TUI view layout is already in
    /// terminal cells, so the panel passes its measured content size directly.
    /// Zero dimensions (a hidden or not-yet-attached container upstream) are
    /// ignored, and an unchanged size is a no-op like xterm's own resize.
    pub fn layout(self: *TerminalInstance, cols: u16, rows: u16) void {
        if (cols == 0 or rows == 0) return;
        if (self.cols == cols and self.rows == rows) return;
        self.resize(cols, rows) catch {
            self.title_error = true;
        };
    }

    pub fn scroll(self: *TerminalInstance, delta: isize) void {
        self.emulator.scrollViewport(delta);
    }

    pub fn scrollToBottom(self: *TerminalInstance) void {
        self.emulator.scrollToBottom();
    }

    pub fn feedBell(self: *TerminalInstance) void {
        self.bell_pending = true;
    }

    pub fn displayTitle(self: *const TerminalInstance) []const u8 {
        if (self.labels.title.len > 0) return self.labels.title;
        if (self.static_title) |title| return title;
        return self.process_name;
    }

    pub fn rename(self: *TerminalInstance, name: []const u8) !void {
        const new_name = if (name.len > 0) try self.allocator.dupe(u8, name) else null;
        if (self.static_title) |title| self.allocator.free(title);
        self.static_title = new_name;
        self.refreshLabel();
    }

    fn refreshLabel(self: *TerminalInstance) void {
        self.labels.refresh(self.allocator, self) catch {};
    }

    pub fn isRunning(self: *const TerminalInstance) bool {
        return self.exit == null and self.process.fd() != null;
    }

    fn hostWrite(context: *anyopaque, data: []const u8) void {
        const self: *TerminalInstance = @ptrCast(@alignCast(context));
        self.writeInput(data);
    }

    fn hostBell(context: *anyopaque) void {
        const self: *TerminalInstance = @ptrCast(@alignCast(context));
        self.feedBell();
    }

    fn hostTitle(context: *anyopaque, title: []const u8) void {
        const self: *TerminalInstance = @ptrCast(@alignCast(context));
        const copy = self.allocator.dupe(u8, title) catch return;
        if (self.sequence) |old| self.allocator.free(old);
        self.sequence = copy;
        self.refreshLabel();
    }

    fn hostPwd(context: *anyopaque, pwd: []const u8) void {
        const self: *TerminalInstance = @ptrCast(@alignCast(context));
        const copy = self.allocator.dupe(u8, pwd) catch return;
        if (self.cwd) |old| self.allocator.free(old);
        self.cwd = copy;
        self.refreshLabel();
    }

    fn hostReset(context: *anyopaque) void {
        const self: *TerminalInstance = @ptrCast(@alignCast(context));
        if (self.sequence) |old| self.allocator.free(old);
        self.sequence = null;
        if (self.cwd) |old| self.allocator.free(old);
        self.cwd = null;
        self.refreshLabel();
    }

    fn hostHold(_: *anyopaque, _: bool) void {}
};

/// Port of `TerminalLabelComputer` from
/// `src/vs/workbench/contrib/terminal/browser/terminalInstance.ts`.
pub const TerminalLabelComputer = struct {
    title: []u8,
    description: []u8,
    title_template: []const u8 = "${process}",
    description_template: []const u8 = "${task}${separator}${local}${separator}${cwdFolder}",
    separator: []const u8 = " - ",
    multi_root: bool = false,

    pub fn init(allocator: Allocator) !TerminalLabelComputer {
        return .{
            .title = try allocator.dupe(u8, ""),
            .description = try allocator.dupe(u8, ""),
        };
    }

    pub fn deinit(self: *TerminalLabelComputer, allocator: Allocator) void {
        allocator.free(self.title);
        allocator.free(self.description);
    }

    pub fn refresh(self: *TerminalLabelComputer, allocator: Allocator, instance: *const TerminalInstance) !void {
        const title = try self.compute(allocator, instance, self.title_template, true);
        errdefer allocator.free(title);
        const description = try self.compute(allocator, instance, self.description_template, false);
        allocator.free(self.title);
        allocator.free(self.description);
        self.title = title;
        self.description = description;
    }

    fn compute(
        self: *const TerminalLabelComputer,
        allocator: Allocator,
        instance: *const TerminalInstance,
        template: []const u8,
        is_title: bool,
    ) ![]u8 {
        const label_template = std.mem.trim(u8, template, " \n\r\t");
        if (label_template.len == 0) {
            if (!is_title) return allocator.dupe(u8, "");
            return allocator.dupe(u8, instance.process_name);
        }
        if (is_title and instance.static_title != null) {
            return sanitize(allocator, instance.static_title.?);
        }

        const cwd = instance.cwd orelse instance.initial_cwd orelse "";
        const cwd_folder = if (cwd.len > 0) blk: {
            if (self.multi_root) break :blk std.fs.path.basename(cwd);
            if (instance.workspace_folder) |folder| {
                if (!std.mem.eql(u8, folder, cwd)) break :blk std.fs.path.basename(cwd);
            }
            break :blk "";
        } else "";

        var out: std.array_list.Managed(u8) = .init(allocator);
        defer out.deinit();
        var pending_separator = false;
        var i: usize = 0;
        while (i < label_template.len) {
            if (std.mem.startsWith(u8, label_template[i..], "${")) {
                if (std.mem.indexOfScalarPos(u8, label_template, i + 2, '}')) |end| {
                    const name = label_template[i + 2 .. end];
                    if (std.mem.eql(u8, name, "separator")) {
                        pending_separator = out.items.len > 0;
                    } else {
                        const value = templateVariable(instance, name, cwd, cwd_folder);
                        if (value.len > 0) {
                            if (pending_separator) try out.appendSlice(self.separator);
                            pending_separator = false;
                            try out.appendSlice(value);
                        }
                    }
                    i = end + 1;
                    continue;
                }
            }
            if (pending_separator) try out.appendSlice(self.separator);
            pending_separator = false;
            try out.append(label_template[i]);
            i += 1;
        }
        const sanitized = try sanitize(allocator, out.items);
        defer allocator.free(sanitized);
        const label = std.mem.trim(u8, sanitized, " ");
        return allocator.dupe(u8, if (is_title and label.len == 0) instance.process_name else label);
    }
};

fn templateVariable(instance: *const TerminalInstance, name: []const u8, cwd: []const u8, cwd_folder: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "process")) return instance.process_name;
    if (std.mem.eql(u8, name, "cwd")) return cwd;
    if (std.mem.eql(u8, name, "cwdFolder")) return cwd_folder;
    if (std.mem.eql(u8, name, "workspaceFolder") or std.mem.eql(u8, name, "workspaceFolderName")) {
        const folder = instance.workspace_folder orelse return "";
        return std.fs.path.basename(folder);
    }
    if (std.mem.eql(u8, name, "sequence")) return instance.sequence orelse "";
    return "";
}

fn sanitize(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    for (value) |ch| {
        if (ch == '\n' or ch == '\r' or ch == '\t') continue;
        try out.append(ch);
    }
    return out.toOwnedSlice();
}

test "TerminalLabelComputer: process/cwd/workspace templates" {
    const allocator = std.testing.allocator;
    var instance = TerminalInstance{
        .allocator = allocator,
        .id = 1,
        .process = undefined,
        .emulator = undefined,
        .cols = 80,
        .rows = 24,
        .process_name = try allocator.dupe(u8, "zsh"),
        .profile_name = try allocator.dupe(u8, "zsh"),
        .initial_cwd = try allocator.dupe(u8, "/root"),
        .workspace_folder = try allocator.dupe(u8, "/root"),
    };
    defer {
        allocator.free(instance.process_name);
        allocator.free(instance.profile_name);
        allocator.free(instance.initial_cwd.?);
        allocator.free(instance.workspace_folder.?);
    }
    var labels = try TerminalLabelComputer.init(allocator);
    defer labels.deinit(allocator);
    labels.title_template = "${process}";
    labels.description_template = "${cwd} - ${workspaceFolder}";
    try labels.refresh(allocator, &instance);
    try std.testing.expectEqualStrings("zsh", labels.title);
    try std.testing.expectEqualStrings("/root - root", labels.description);

    labels.description_template = "${task}${separator}${local}${separator}${cwdFolder}";
    try labels.refresh(allocator, &instance);
    try std.testing.expectEqualStrings("", labels.description);
    labels.description_template = "${process}${separator}${task}${separator}${workspaceFolder}${separator}";
    try labels.refresh(allocator, &instance);
    try std.testing.expectEqualStrings("zsh - root", labels.description);
}
