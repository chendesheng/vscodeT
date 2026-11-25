const std = @import("std");
const TestWindow = @import("../vs/workbench/test/browser/workbenchTestServices.zig").TestWindow;
const builtin = @import("builtin");
const Io = std.Io;
const tui = @import("./tui.zig");
const vscode_profile = @import("./vscodeProfile.zig");
const ui = @import("ui");
const input = ui.input;
const terminal_input = @import("../vs/workbench/contrib/terminal/browser/terminalInput.zig");
const Editor = @import("../vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const editorInputDispatch = @import("./editorInputDispatch.zig");
const handleKeyEvent = editorInputDispatch.handleKeyEvent;
const View = @import("./editorView.zig").View;
const terminal_workbench = @import("workbench.zig");
const TerminalWorkbench = terminal_workbench.TerminalWorkbench;
const Workbench = terminal_workbench.Workbench;
const extensions = @import("../vs/workbench/api/browser/extensionHostAdapter.zig");
const extensions_registry = @import("../vs/workbench/services/extensions/common/extensionsRegistry.zig");
const VimRuntime = @import("../vs/workbench/contrib/vim/browser/vimRuntime.zig").VimRuntime;
const HelixRuntime = @import("../vs/workbench/contrib/helix/browser/helixRuntime.zig").HelixRuntime;
const json_language = @import("../vs/workbench/services/language/common/jsonLanguageClient.zig");
const session = @import("../vs/workbench/browser/parts/editor/editorSession.zig");
const FileEditorSerializer = @import("../vs/workbench/contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorSerializer;
const ImagePreviewEditorInput = @import("../vs/workbench/contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInput;
const ImagePreviewEditorInputSerializer = @import("../vs/workbench/contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInputSerializer;
const FileEditorInput = @import("../vs/workbench/contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const EditorFactoryRegistry = @import("../vs/workbench/common/editor/editorFactory.zig").EditorFactoryRegistry;
const FindController = @import("../vs/editor/contrib/find/browser/findController.zig").FindController;
const word_character_classifier = @import("../vs/editor/common/core/wordCharacterClassifier.zig");
const editorBrowser = @import("../vs/editor/browser/editorBrowser.zig");
const Position = @import("../vs/editor/common/core/position.zig").Position;
const Range = @import("../vs/editor/common/core/range.zig").Range;
const Selection = @import("../vs/editor/common/core/selection.zig").Selection;
const time_compat = @import("../vs/base/common/timeCompat.zig");
const logger = @import("../vs/platform/log/common/fileLog.zig");
const log_module = @import("../vs/platform/log/common/log.zig");
const languages = @import("../vs/editor/common/languages.zig");
const hoverTypes = @import("../vs/editor/contrib/hover/browser/hoverTypes.zig");
const ContentHoverController = @import("../vs/editor/contrib/hover/browser/contentHoverController.zig").ContentHoverController;
const MarkdownHoverParticipant = @import("../vs/editor/contrib/hover/browser/markdownHoverParticipant.zig").MarkdownHoverParticipant;
const WordHighlighterContribution = @import("../vs/editor/contrib/wordHighlighter/browser/wordHighlighter.zig").WordHighlighterContribution;
const SuggestController = @import("../vs/editor/contrib/suggest/browser/suggestController.zig").SuggestController;
const WordBasedCompletionProvider = @import("../vs/editor/contrib/suggest/browser/wordBasedSuggestions.zig").WordBasedCompletionProvider;
const TuiHoverProvider = @import("../vs/editor/contrib/hover/browser/terminalHoverProvider.zig").TuiHoverProvider;
const ArrayList = std.array_list.Managed;

/// Process-wide `std.log` sink. The TUI owns the terminal, so engine
/// diagnostics (libghostty-vt's parser included) must never reach stderr while
/// the alternate screen is active; they are routed through the workbench
/// logger instead.
var std_log_sink: ?log_module.ILogger = null;
/// True while the alternate screen owns the terminal.
var screen_owns_terminal = false;

/// `std.log` hook installed as `std_options.logFn` in `src/main.zig`. While the
/// workbench log file is available every engine log line goes there (the file
/// logger's level decides which levels are kept). With no log file, logs are
/// dropped as soon as the TUI owns the screen; before that stderr is still a
/// useful destination.
pub fn logStd(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const mapped: log_module.LogLevel = switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warning,
        .err => .err,
    };
    if (std_log_sink) |sink| {
        if (!log_module.canLog(sink.getLevel(), mapped)) return;
        var buffer: [4096]u8 = undefined;
        const scoped_format: []const u8 = if (scope == .default)
            format
        else
            @tagName(scope) ++ ": " ++ format;
        const text = std.fmt.bufPrint(&buffer, scoped_format, args) catch return;
        log_module.log(sink, mapped, text) catch {};
        return;
    }
    if (screen_owns_terminal) return;
    std.log.defaultLog(level, scope, format, args);
}

/// Mirrors the previous `std.debug.print` error reporting, now also written to
/// the main log file. While the alternate screen is active the message goes to
/// the log only: a direct stderr write would paint over the cell grid.
const WillShutdownEvent = @import("../vs/workbench/services/lifecycle/common/lifecycle.zig").WillShutdownEvent;
pub fn startWorkbench(allocator: std.mem.Allocator, io: std.Io, surface: *ui.Surface, paths: []const []const u8, previous: ?Workbench.PreviousState) !*Workbench {
    var services = try @import("../vs/workbench/workbench.common.main.zig").createServices(allocator);
    defer services.deinit();
    const workbench = try Workbench.init(allocator, io, surface, &services, .{}, previous);
    errdefer workbench.deinit();
    _ = try workbench.startup();
    for (paths) |path| try workbench.openPath(path);
    return workbench;
}

const SessionOnShutdown = struct {
    workbench: *Workbench,
    registry: *EditorFactoryRegistry,
    path: []const u8,
    log: ?log_module.ILogger,

    fn save(_: WillShutdownEvent, self: *@This()) !void {
        if (self.workbench.tabCount() == 0) return;
        const allocator = self.workbench.allocator;
        var data = self.workbench.part.createState(allocator, self.registry) catch |err| {
            report(self.log, "session serialize failed: {s}", .{@errorName(err)});
            return;
        };
        defer data.deinit(allocator);
        session.savePart(allocator, self.workbench.io, self.path, &data) catch |err| {
            report(self.log, "session save failed: {s}", .{@errorName(err)});
        };
    }
};

fn report(log_service: ?log_module.ILogger, comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    if (!screen_owns_terminal) std.debug.print("{s}\n", .{text});
    const logger_value = log_service orelse return;
    logger_value.err(.{ .string = text }, &.{}) catch {};
}

fn infoLog(log_service: ?log_module.ILogger, comptime fmt: []const u8, args: anytype) void {
    const logger_value = log_service orelse return;
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    logger_value.info(text, &.{}) catch {};
}

const Args = struct {
    preview: bool = false,
    session: ?[]const u8 = null,
    extensions_dir: ?[]const u8 = null,
    user_data_dir: ?[]const u8 = null,
    logs_path: ?[]const u8 = null,
};

/// Parses upstream VS Code's path switches (`--user-data-dir`,
/// `--extensions-dir`, `--logsPath`), `--preview`, `--session <file>` and the
/// remaining paths. `--preview` is only valid with exactly one path;
/// `--session` restores the saved group when the file exists and otherwise
/// opens the given paths.
/// Returns the value of `--name=value`, the form upstream's argv parser also
/// accepts for string options.
fn inlineOption(arg: []const u8, name: []const u8) ?[]const u8 {
    if (arg.len <= name.len or !std.mem.startsWith(u8, arg, name) or arg[name.len] != '=') return null;
    return arg[name.len + 1 ..];
}

fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args, paths: *ArrayList([]const u8)) !Args {
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next(); // executable name

    var parsed: Args = .{};
    errdefer if (parsed.session) |session_path| allocator.free(session_path);
    errdefer if (parsed.extensions_dir) |path| allocator.free(path);
    errdefer if (parsed.user_data_dir) |path| allocator.free(path);
    errdefer if (parsed.logs_path) |path| allocator.free(path);
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--preview")) {
            parsed.preview = true;
        } else if (std.mem.eql(u8, arg, "--session")) {
            const value = it.next() orelse return error.MissingSessionPath;
            if (parsed.session) |old| allocator.free(old);
            parsed.session = try allocator.dupe(u8, value);
        } else if (inlineOption(arg, "--extensions-dir") orelse (if (std.mem.eql(u8, arg, "--extensions-dir")) it.next() orelse return error.MissingExtensionsDir else null)) |value| {
            if (parsed.extensions_dir) |old| allocator.free(old);
            parsed.extensions_dir = try allocator.dupe(u8, value);
        } else if (inlineOption(arg, "--user-data-dir") orelse (if (std.mem.eql(u8, arg, "--user-data-dir")) it.next() orelse return error.MissingUserDataDir else null)) |value| {
            if (parsed.user_data_dir) |old| allocator.free(old);
            parsed.user_data_dir = try allocator.dupe(u8, value);
        } else if (inlineOption(arg, "--logsPath") orelse (if (std.mem.eql(u8, arg, "--logsPath")) it.next() orelse return error.MissingLogsPath else null)) |value| {
            if (parsed.logs_path) |old| allocator.free(old);
            parsed.logs_path = try allocator.dupe(u8, value);
        } else {
            const copy = try allocator.dupe(u8, arg);
            errdefer allocator.free(copy);
            try paths.append(copy);
        }
    }

    if (parsed.preview and parsed.session != null) return error.PreviewWithSession;
    if (parsed.preview and paths.items.len != 1) return error.InvalidPreviewPaths;
    return parsed;
}

/// Terminals that implement Unicode placeholders but predate the kitty 0.50
/// feature query, so `ui.image.probe` cannot confirm them from its reply.
/// Ghostty and Rex share the libghostty terminal engine; kitty before 0.50 is
/// recognized through `KITTY_WINDOW_ID`.
fn terminalPlaceholderHint(environ: *const std.process.Environ.Map) bool {
    if (environ.get("KITTY_WINDOW_ID") != null) return true;
    if (environ.get("TERM_PROGRAM")) |program| {
        if (std.ascii.eqlIgnoreCase(program, "ghostty")) return true;
        if (std.ascii.eqlIgnoreCase(program, "rex")) return true;
    }
    if (environ.get("TERM")) |term| {
        if (std.ascii.eqlIgnoreCase(term, "xterm-ghostty")) return true;
        if (std.ascii.eqlIgnoreCase(term, "xterm-rex")) return true;
    }
    return false;
}

test "app: Ghostty and Rex environments enable Unicode placeholders" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();

    try environ.put("TERM", "xterm-256color");
    try std.testing.expect(!terminalPlaceholderHint(&environ));

    try environ.put("TERM_PROGRAM", "rex");
    try std.testing.expect(terminalPlaceholderHint(&environ));

    try environ.put("TERM_PROGRAM", "vscode");
    try std.testing.expect(!terminalPlaceholderHint(&environ));

    try environ.put("TERM", "xterm-rex");
    try std.testing.expect(terminalPlaceholderHint(&environ));
}

const ProbeHost = struct {
    io: Io,

    fn poll(_: *anyopaque, timeout_ms: i32) anyerror!bool {
        return tui.pollInput(timeout_ms);
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) anyerror!void {
        const self: *ProbeHost = @ptrCast(@alignCast(context));
        var bytes = std.array_list.Managed(u8).init(allocator);
        defer bytes.deinit();
        const read_bytes = try tui.readFd(self.io, 0, &bytes);
        try buffer.appendSlice(allocator, read_bytes);
    }
};

/// The runtime's Debug allocator records a stack trace for every allocation
/// and free; the profile shows that unwinding is 70-94% of active CPU for the
/// default build. Keep the debug allocator's safety and leak checks but skip
/// the traces for the long-running TUI process. Tests keep using the testing
/// allocator, which reports full traces.
var app_debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .{};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = if (comptime builtin.mode == .debug) app_debug_allocator.allocator() else init.gpa;
    defer if (comptime builtin.mode == .debug) {
        if (app_debug_allocator.deinit() == .leak) {
            std.debug.print("app allocator: allocations leaked at exit\n", .{});
        }
    };
    const startup_start_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();

    var paths = ArrayList([]const u8).init(allocator);
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit();
    }

    const args = parseArgs(allocator, init.minimal.args, &paths) catch {
        std.debug.print(
            "usage: zig <folder> [<file>...]\n       zig <file>...\n       zig --session <file> [<folder>] [<file>...]\n       zig --preview <file>\n       zig [--user-data-dir <dir>] [--extensions-dir <dir>] [--logsPath <dir>] [<folder>|<file>...]\n",
            .{},
        );
        return;
    };
    defer if (args.session) |session_path| allocator.free(session_path);
    defer if (args.extensions_dir) |path| allocator.free(path);
    defer if (args.user_data_dir) |path| allocator.free(path);
    defer if (args.logs_path) |path| allocator.free(path);

    // Profile discovery resolves the TUI user-data dir with upstream's
    // `VSCODE_PORTABLE`/`VSCODE_APPDATA`/`--user-data-dir` precedence and the
    // extensions path with `--extensions-dir`/`VSCODE_EXTENSIONS`/
    // `VSCODE_PORTABLE`. The VS Code `Code/User` profile is the base layer.
    var vscode_environment = vscode_profile.Environment.fromProcess(init.environ_map);
    vscode_environment.cli_extensions_dir = args.extensions_dir;
    vscode_environment.cli_user_data_dir = args.user_data_dir;
    vscode_environment.cli_logs_path = args.logs_path;
    var profile = try vscode_profile.discover(allocator, vscode_environment);
    defer profile.deinit();

    var file_logger: ?*logger.FileLogger = null;
    const log_path = profile.mainLogPath(allocator) catch null;
    defer if (log_path) |path| allocator.free(path);
    if (log_path) |path| {
        file_logger = logger.FileLogger.create(allocator, io, path) catch |err| blk: {
            std.debug.print("log file unavailable: {s}\n", .{@errorName(err)});
            break :blk null;
        };
    }
    defer if (file_logger) |value| value.destroy();
    const log_service: ?log_module.ILogger = if (file_logger) |value| value.logger() else null;
    // Route `std.log` (the embedded terminal engine uses it) into the workbench
    // log instead of the tty. Cleared before the file logger is destroyed.
    std_log_sink = log_service;
    defer std_log_sink = null;
    defer infoLog(log_service, "exit", .{});
    infoLog(log_service, "starting: preview={} session={s} paths={d}", .{
        args.preview,
        args.session orelse "-",
        paths.items.len,
    });

    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_dir);
    const installed_extensions = try std.fs.path.resolveAlloc(allocator, &.{ executable_dir, "../share/vscode-textbuffer/extensions" });
    defer allocator.free(installed_extensions);
    var declarative: ?extensions_registry.Registry = extensions_registry.scan(allocator, &.{installed_extensions}) catch |err| blk: {
        report(log_service, "built-in extension scan failed: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (declarative) |*registry| registry.deinit();
    const tokenizer = @import("../vs/editor/common/model/tokens/textMateTokenizer.zig");
    if (declarative) |*registry| tokenizer.setGrammarCatalog(registry.grammars);
    defer tokenizer.setGrammarCatalog(&.{});

    const runtime_dir = try std.fs.path.resolveAlloc(allocator, &.{ executable_dir, "../lib/vscode-textbuffer" });
    defer allocator.free(runtime_dir);
    const json_server = try std.fs.path.join(allocator, &.{ runtime_dir, "jsonServer.mjs" });
    defer allocator.free(json_server);
    var json_client: ?*json_language.Client = null;
    if (std.Io.Dir.cwd().access(time_compat.io, json_server, .{})) |_| {
        json_client = json_language.Client.start(allocator, "node", json_server) catch |err| blk: {
            infoLog(log_service, "JSON language server unavailable: {s}", .{@errorName(err)});
            break :blk null;
        };
    } else |_| {}
    defer if (json_client) |client| client.deinit();

    // The whole-word search classifier cache is process-lifetime by design;
    // release it before the safe allocator checks for leaks on exit.
    defer word_character_classifier.freeWordClassifierCache();

    var out_buffer: [65536]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const orig_termios = try tui.enableRawMode();
    tui.rememberOrigTermios(orig_termios);
    defer tui.disableRawMode(orig_termios) catch {};

    try tui.enableBracketedPaste(out);
    defer tui.disableBracketedPaste(out) catch {};

    try tui.enterAltScreen(out);
    defer tui.exitAltScreen(out) catch {};
    screen_owns_terminal = true;
    defer screen_owns_terminal = false;

    try tui.disableLineWrap(out);
    defer tui.enableLineWrap(out) catch {};

    try tui.enableMouseCapture(out);
    defer tui.disableMouseCapture(out) catch {};
    // Restore the terminal pointer shape on the way out (both the workbench
    // and the read-only preview may have set a non-default OSC 22 shape).
    defer ui.pointer.writeShape(out, .default) catch {};

    try tui.installSigWinch();

    const size = try tui.getTerminalSize();

    if (args.preview) {
        var editor = try Editor.createWithExtensions(allocator, io, paths.items[0], size.width, size.height, if (declarative) |*registry| registry else null, json_client);
        defer {
            editor.deinit();
            allocator.destroy(editor);
        }
        try runPreview(allocator, io, out, editor, size, json_client);
        return;
    }

    // Probe once, inside the alternate screen, before the first frame: the
    // answer decides whether borders reserve cells or paint on cell edges.
    var probe_host = ProbeHost{ .io = io };
    const border_probe = try ui.cell_border.probe(allocator, io, out, .{
        .context = &probe_host,
        .poll = ProbeHost.poll,
        .read = ProbeHost.read,
    });
    defer border_probe.deinit(allocator);
    infoLog(log_service, "cell borders: supported={} version={d} features=0x{x}", .{
        border_probe.supported,
        border_probe.capabilities.version,
        border_probe.capabilities.features,
    });

    // The kitty graphics probe is separate because its replies are APC
    // strings rather than the cell-border DCS. Known placeholder-capable
    // terminals that predate the 0.50 feature query are recognized through
    // their environment; the query wins when the terminal answers it.
    const image_probe = ui.image.probe(
        allocator,
        io,
        out,
        .{ .context = &probe_host, .poll = ProbeHost.poll, .read = ProbeHost.read },
        terminalPlaceholderHint(init.environ_map),
    ) catch |err| blk: {
        infoLog(log_service, "image protocol probe failed: {s}", .{@errorName(err)});
        break :blk ui.image.ProbeResult{};
    };
    defer image_probe.deinit(allocator);
    infoLog(log_service, "image protocol: {s} (graphics={} feature={})", .{
        @tagName(image_probe.capability),
        image_probe.graphics_ok,
        image_probe.feature_ok,
    });

    var folders = ArrayList([]u8).init(allocator);
    defer {
        for (folders.items) |folder| allocator.free(folder);
        folders.deinit();
    }
    var files = ArrayList([]const u8).init(allocator);
    defer files.deinit();

    const cwd = Io.Dir.cwd();
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = cwd.realPath(io, &cwd_buffer) catch 0;
    const cwd_path = cwd_buffer[0..cwd_len];

    for (paths.items) |path| {
        const stat = cwd.statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (stat) |info| {
            if (info.kind == .directory) {
                try folders.append(try std.fs.path.resolveAlloc(allocator, &.{ cwd_path, path }));
                continue;
            }
        }
        try files.append(path);
    }

    if (args.session == null and folders.items.len == 0 and files.items.len == 0) {
        report(log_service, "no files or folders to open", .{});
        return;
    }

    var file_serializer: ?FileEditorSerializer = null;
    var image_serializer: ?ImagePreviewEditorInputSerializer = null;
    var registry: ?EditorFactoryRegistry = null;
    if (args.session != null) {
        // The workbench status bar takes one row and each group's tab strip
        // takes one; restored editors are opened as workbench panes, so their
        // content height is the remaining rows.
        const restored_editor_height = @max(size.height -| 2, 1);
        file_serializer = FileEditorSerializer.init(allocator, io, size.width, restored_editor_height);
        image_serializer = ImagePreviewEditorInputSerializer.init(allocator);
        registry = EditorFactoryRegistry.init(allocator);
        try registry.?.registerEditorSerializer(FileEditorInput.TYPE_ID, file_serializer.?.interface());
        try registry.?.registerEditorSerializer(ImagePreviewEditorInput.ID, image_serializer.?.interface());
    }
    defer if (registry) |*value| value.deinit();

    var surface: ui.Surface = undefined;
    try terminal_workbench.initWindowSurface(&surface, allocator, size.width, size.height);
    defer surface.deinit();
    var workbench: *Workbench = undefined;
    var restored = false;
    if (args.session) |session_path| {
        const loaded = session.loadPart(allocator, io, session_path) catch |err| blk: {
            report(log_service, "session load failed: {s}", .{@errorName(err)});
            break :blk null;
        };
        if (loaded) |data| {
            var owned = data;
            defer owned.deinit(allocator);

            const created = startWorkbench(allocator, io, &surface, &.{}, .{ .data = data, .registry = &registry.? }) catch |err| blk: {
                report(log_service, "session restore failed: {s}", .{@errorName(err)});
                break :blk @as(?*Workbench, null);
            };

            if (created) |candidate| {
                workbench = candidate;
                restored = true;
            }
        }
    }

    if (restored) {
        infoLog(log_service, "session restored: {d} tab(s)", .{workbench.tabCount()});
    }
    if (!restored) {
        if (files.items.len == 0 and folders.items.len == 0) {
            report(log_service, "no files or folders to open and no restorable session", .{});
            return;
        }
        workbench = try startWorkbench(allocator, io, &surface, &.{}, null);
    }
    infoLog(log_service, "startup: workbench-init={d}ms", .{
        std.Io.Timestamp.now(io, .awake).toMilliseconds() - startup_start_ms,
    });
    defer workbench.deinit();
    workbench.setCellBorderCapabilities(if (border_probe.supported) border_probe.capabilities else null);
    workbench.setImageProtocol(image_probe.capability);
    workbench.setCellPixelSize(size.cell_width_px, size.cell_height_px);
    // OSC 22 needs no probe: a terminal without pointer-shape support ignores
    // the sequence and the frame is unaffected.
    workbench.setPointerShapes(true);
    if (declarative) |*decl_ext| workbench.setDeclarativeExtensions(decl_ext);
    workbench.enableAsyncTokenization();
    workbench.enableLanguageFeatures() catch |err| report(log_service, "language features unavailable: {s}", .{@errorName(err)});
    workbench.setJsonLanguageClient(json_client);

    try workbench.setUserSettingsPaths(profile.settings_paths);
    try workbench.setKeybindingsPaths(profile.keybindings_paths);
    const HistoryStorage = @import("historyStorage.zig").HistoryStorage;
    var history_storage: HistoryStorage = undefined;
    const history_path = if (profile.user_data_dir) |dir| try std.fs.path.join(allocator, &.{ dir, "history.json" }) else null;
    defer if (history_path) |path| allocator.free(path);
    if (profile.user_data_dir) |dir| workbench.setTerminalProfileStorage(dir) catch {};
    if (history_path) |path| {
        history_storage = .{ .history = &workbench.history, .allocator = allocator, .io = io, .path = path };
        try history_storage.load();
        _ = try workbench.on_will_shutdown.listen(&history_storage, HistoryStorage.save);
    }

    if (folders.items.len > 0) {
        try workbench.setWorkspaceFolders(folders.items);
    }
    try workbench.initSidebarFromWorkspace();
    if (!restored) {
        for (files.items) |path| try workbench.openPath(path);
    }

    // Native Vim and Helix are compiled-in modal built-ins. Their runtimes
    // register Enable/Disable even while the startup settings are false.
    // Only one modal built-in may consume keys at a time; enabling either one
    // disables and persists the other off.
    const vim_runtime = try VimRuntime.init(allocator, workbench.builtin_host);
    defer vim_runtime.deinit();
    const helix_runtime = try HelixRuntime.init(allocator, workbench.builtin_host);
    defer helix_runtime.deinit();
    vim_runtime.setOnEnable(.{ .context = helix_runtime, .on_enable = disableHelixForVim });
    helix_runtime.setOnEnable(.{ .context = vim_runtime, .on_enable = disableVimForHelix });

    const vim_enabled = if (workbench.configuration) |configuration|
        configuration.getBool("vim.enabled", false)
    else
        false;
    const helix_enabled = if (workbench.configuration) |configuration|
        configuration.getBool("helix.enabled", false)
    else
        false;
    if (helix_enabled) {
        if (vim_enabled) vim_runtime.setEnabledPersistent(false) catch {};
        try helix_runtime.enable();
        if (vim_enabled) {
            if (workbench.activeTab()) |tab| tab.editor.setMessage("Only one modal mode can be active; Helix takes precedence", .{});
        }
    } else if (vim_enabled) {
        try vim_runtime.enable();
    }
    infoLog(log_service, "startup: settings-modal={d}ms", .{
        std.Io.Timestamp.now(io, .awake).toMilliseconds() - startup_start_ms,
    });

    // Color themes: the built-in theme-defaults contributions first, then the
    // profile's extensions path (later registrations win). A missing submodule leaves only the fallback
    // syntax theme installed by the workbench.
    var theme_roots = ArrayList([]const u8).init(allocator);
    defer theme_roots.deinit();
    if (profile.extensions_dir) |dir| theme_roots.append(dir) catch {};
    var extra_themes: ?extensions_registry.ThemeList = null;
    if (theme_roots.items.len > 0) {
        extra_themes = extensions_registry.scanThemes(allocator, theme_roots.items) catch |err| blk: {
            infoLog(log_service, "theme scan failed: {s}", .{@errorName(err)});
            break :blk null;
        };
    }
    defer if (extra_themes) |*list| list.deinit();
    if (declarative) |*decl_ext| {
        workbench.registerThemeSources(decl_ext.themes) catch |err| {
            report(log_service, "built-in themes unavailable: {s}", .{@errorName(err)});
        };
    }
    if (extra_themes) |*list| {
        workbench.registerThemeSources(list.themes) catch |err| {
            report(log_service, "installed themes unavailable: {s}", .{@errorName(err)});
        };
    }
    workbench.applyThemeSettings();
    infoLog(log_service, "startup: themes={d}ms", .{
        std.Io.Timestamp.now(io, .awake).toMilliseconds() - startup_start_ms,
    });
    workbench.configureJsonLanguage();

    var session_writer: SessionOnShutdown = undefined;
    if (args.session) |session_path| {
        session_writer = .{ .workbench = workbench, .registry = &registry.?, .path = session_path, .log = log_service };
        _ = try workbench.on_will_shutdown.listen(&session_writer, SessionOnShutdown.save);
    }

    workbench.initGit() catch {};
    if (profile.user_data_dir) |user_data| workbench.setSidebarViewStorage(user_data) catch {};
    const LayoutStorage = @import("layoutStorage.zig").LayoutStorage;
    var layout_storage: ?LayoutStorage = if (profile.user_data_dir) |dir| try .init(workbench, dir, args.session) else null;
    defer if (layout_storage) |*storage| storage.deinit();
    var saved_layout: ?@import("../vs/workbench/browser/layout.zig").Layout.WorkspaceState = null;
    if (layout_storage) |*storage| {
        if (storage.load(workbench.layout.reset_layout)) |saved| {
            saved_layout = saved;
            _ = try workbench.on_will_shutdown.listen(storage, LayoutStorage.save);
        } else |err| report(log_service, "layout restore failed: {s}", .{@errorName(err)});
    }
    if (workbench.activeTab()) |active| {
        try active.ensureControllers();
    } else {
        workbench.focusSidebar();
    }
    infoLog(log_service, "startup: workspace-git={d}ms", .{
        std.Io.Timestamp.now(io, .awake).toMilliseconds() - startup_start_ms,
    });

    var extension_host: ?*extensions.Extensions = null;
    defer if (extension_host) |ext| ext.deinit();
    var extension_paths = std.array_list.Managed(extensions.Extensions.ExtensionPath).init(allocator);
    defer {
        for (extension_paths.items) |entry| allocator.free(entry.path);
        extension_paths.deinit();
    }
    if (declarative) |*catalog| {
        for (catalog.extensions) |extension| {
            const path = try std.fs.path.join(allocator, &.{ runtime_dir, "extensions", std.fs.path.basename(extension.root) });
            errdefer allocator.free(path);
            if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
                try extension_paths.append(.{ .path = path, .is_builtin = true });
            } else |err| {
                if (err != error.FileNotFound) infoLog(log_service, "extension unavailable at {s}: {s}", .{ path, @errorName(err) });
                allocator.free(path);
            }
        }
    }
    if (extension_paths.items.len > 0) {
        if (profile.user_data_dir) |user_data_dir| {
            std.Io.Dir.cwd().createDirPath(io, user_data_dir) catch {};
            extension_host = extensions.Extensions.init(allocator, io, workbench, extension_paths.items, user_data_dir, runtime_dir) catch |err| blk: {
                if (err == error.ExtensionHostBundleMissing) {
                    report(log_service, "extension host disabled: installed extensionHost.mjs is missing; run `zig build host` (details in README)", .{});
                } else {
                    report(log_service, "extension host disabled: {s}", .{@errorName(err)});
                }
                break :blk null;
            };
        } else {
            infoLog(log_service, "extension host disabled: no user data directory", .{});
        }
    } else {
        infoLog(log_service, "extension host disabled: no executable built-ins installed", .{});
    }
    infoLog(log_service, "startup: extension-host={d}ms", .{
        std.Io.Timestamp.now(io, .awake).toMilliseconds() - startup_start_ms,
    });

    var needs_render = false;
    var terminal_host = try TerminalWorkbench.init(workbench, out, border_probe.leftover, image_probe.leftover);
    defer terminal_host.deinit();
    terminal_host.scheduleFrames(&needs_render);

    try tui.hideCursor(out);
    defer tui.showCursor(out) catch {};

    var restore_timer = @import("../vs/base/common/async.zig").WindowTimer{
        .clock = .{ .context = workbench, .now = struct {
            fn now(ctx: *anyopaque) i64 {
                const wb: *Workbench = @ptrCast(@alignCast(ctx));
                return std.Io.Timestamp.now(wb.io, .awake).toMilliseconds();
            }
        }.now },
    };
    workbench.restore(&restore_timer, saved_layout) catch |err| report(log_service, "workbench restore failed: {s}", .{@errorName(err)});
    infoLog(log_service, "workbench ready: {d} tab(s)", .{workbench.tabCount()});
    workbench.refreshStatus();
    if (workbench.activeTab()) |active| try active.view.refresh();
    try terminal_host.render();
    infoLog(log_service, "startup: first-frame={d}ms active-editor-wraps={d}", .{
        std.Io.Timestamp.now(io, .awake).toMilliseconds() - startup_start_ms,
        if (workbench.activeTab()) |active| active.editor.view_lines.rebuildAllCount() else 0,
    });

    defer workbench.lifecycle.shutdown(.quit) catch |err| report(log_service, "shutdown failed: {s}", .{@errorName(err)});
    // Last frame that was only caused by a background-tokenization chunk.
    var last_token_render_ms: i64 = 0;
    const outline_models = try workbench.instantiation.invokeFunction(@import("../vs/editor/contrib/documentSymbols/browser/outlineModel.zig").getOutlineModelService, .{});
    while (true) {
        const now_ms = time_compat.milliTimestamp();
        if (workbench.pollFileWatcher(now_ms)) needs_render = true;
        if (try workbench.pollQuickAccess(now_ms)) needs_render = true;
        if (workbench.pollSearch(now_ms)) needs_render = true;
        if (workbench.pollGit(now_ms)) needs_render = true;
        if (workbench.markdownPreviewTick(now_ms)) needs_render = true;
        if (workbench.tickEditorDrag(now_ms)) needs_render = true;
        if (workbench.pollAsyncReads()) needs_render = true;
        if (json_client) |client| {
            if (client.dispatchResponses(false)) needs_render = true;
        }
        if (extension_host) |ext| {
            if (ext.pump()) needs_render = true;
        }
        var timeout: i32 = 250;
        if (workbench.activeTab()) |active| {
            try active.ensureControllers();
            if (active.controllers) |controllers| {
                if (active.editor.inPlaceReplaceTick(now_ms)) needs_render = true;
                if (controllers.hover.onTick(now_ms)) needs_render = true;
                if (controllers.word_highlighter.onTick(now_ms)) needs_render = true;
                if (controllers.sticky.onTick(now_ms)) needs_render = true;
                if (try controllers.suggest.onTick(now_ms)) needs_render = true;

                timeout = controllers.hover.pollTimeout(now_ms, 250);
                if (active.editor.inPlaceReplacePollTimeout(now_ms)) |replace_timeout| {
                    timeout = @min(timeout, @as(i32, @intCast(@min(replace_timeout, 250))));
                }
                if (controllers.word_highlighter.pollTimeout(now_ms)) |word_timeout| {
                    timeout = @min(timeout, @as(i32, @intCast(@min(word_timeout, 250))));
                }
                if (controllers.suggest.pollTimeout(now_ms)) |suggest_timeout| {
                    timeout = @min(timeout, @as(i32, @intCast(@min(suggest_timeout, 250))));
                }
                if (controllers.sticky.pollTimeout(now_ms)) |sticky_timeout| {
                    timeout = @min(timeout, @as(i32, @intCast(@min(sticky_timeout, 250))));
                }
            }
        }
        timeout = outline_models.dispatchTimers(now_ms, timeout);
        if (workbench.editorDragTimeout(now_ms)) |drag_timeout| timeout = @min(timeout, drag_timeout);
        if (workbench.gitWantsTick()) timeout = @min(timeout, 200);
        if (workbench.markdownPreviewTimeout(now_ms)) |preview_timeout| {
            timeout = @min(timeout, @as(i32, @intCast(@min(preview_timeout, 250))));
        }
        timeout = workbench.quick_access.pollTimeout(now_ms, timeout);
        if (workbench.searchWantsTick()) timeout = 0;
        if (workbench.fileWatcherTimeout(now_ms)) |watcher_timeout| {
            timeout = @min(timeout, @as(i32, @intCast(@min(watcher_timeout, 250))));
        }
        if (workbench.foldingTimeout(now_ms)) |folding_timeout| {
            timeout = @min(timeout, @as(i32, @intCast(@min(folding_timeout, 250))));
        }
        if (workbench.bracketGuidesTimeout(now_ms)) |guides_timeout| {
            timeout = @min(timeout, @as(i32, @intCast(@min(guides_timeout, 250))));
        }
        if (workbench.backgroundTokenizationPending()) timeout = @min(timeout, 4);
        if (workbench.hasLatencySensitiveReads()) timeout = @min(timeout, 4);

        timeout = restore_timer.nextTimeout(timeout);
        const polled = try terminal_host.wait(if (needs_render) 0 else timeout);
        if (polled.redraw) needs_render = true;
        const ready = polled.input or terminal_host.hasBufferedInput();
        try restore_timer.dispatch(!ready and !needs_render);
        const resized = try terminal_host.handleResize();

        if (workbench.drainBackgroundTokenization()) needs_render = true;

        if (!ready) {
            // Only spend deferred analysis when no input is buffered, so rapid
            // typing is echoed before syntax colors/folding/guides catch up.
            // Run at most one heavy pass per idle tick.
            var maintenance = workbench.pollFolding(now_ms);
            if (!maintenance) maintenance = workbench.pollBracketGuides(now_ms);
            const token_maintenance = workbench.pollBackgroundTokenization();
            if (token_maintenance) maintenance = true;
            if (maintenance) needs_render = true;
            // Background tokenization yields ~1 ms chunks. Repainting every
            // chunk made the frame cost part of tokenization; coalesce those
            // repaints to roughly one per 8 ms. The final chunk always paints
            // (the pending flag is false), and input/folding/guide passes are
            // not delayed.
            const coalesce_token_frame = token_maintenance and
                !resized and
                workbench.backgroundTokenizationPending() and
                now_ms - last_token_render_ms < 8;
            if (resized or (needs_render and !coalesce_token_frame)) {
                if (workbench.activeTab()) |current| {
                    current.onEditorChanged(now_ms);
                    workbench.onSearchEditorChanged();
                    try current.refresh();
                }
                workbench.refreshStatus();
                needs_render = false;
                try terminal_host.render();
                if (token_maintenance) last_token_render_ms = now_ms;
            }
            continue;
        }

        const batch = try terminal_host.readEvents(polled.input);
        var events = batch.decoded.items;
        defer events.deinit(allocator);
        if (batch.pasted) needs_render = true;

        var sidebar_event_count: usize = 0;
        for (events.items) |*item| {
            if (extension_host) |ext| {
                // The next pump reports a selection delta tagged with the
                // source of this event.
                ext.selection_source = switch (item.*) {
                    .key => .keyboard,
                    .mouse => .mouse,
                    .focus => ext.selection_source,
                };
            }
            switch (item.*) {
                .focus => |focused| {
                    if (!focused) {
                        if (workbench.context_menu_service.current != null) {
                            workbench.context_menu_service.hideContextMenu();
                            needs_render = true;
                        }
                        if (workbench.cancelEditorDrag()) needs_render = true;
                        if (workbench.cancelSashDrag()) needs_render = true;
                    }
                },
                .key => |*event| {
                    if (event.key == .escape and workbench.cancelEditorDrag()) {
                        needs_render = true;
                        continue;
                    }
                    // The save confirmation is modal: it owns every key,
                    // including the global quit shortcut.
                    if (workbench.handleDialogKey(event)) {
                        if (workbench.shouldQuit()) return;
                        continue;
                    }
                    if (workbench.context_menu_service.handleKey(event)) continue;
                    if (workbench.handleBreadcrumbPopupKey(event)) continue;
                    if (isCtrlQ(event.*)) {
                        if (workbench.requestQuit()) return;
                        continue;
                    }
                    workbench.clearStatusHover();

                    if (try workbench.handleQuickAccessKey(event)) continue;
                    if (try workbench.handleTerminalKey(event)) continue;
                    if (try workbench.handlePanelKey(event)) continue;
                    if (try workbench.handleSidebarKey(event)) {
                        sidebar_event_count += 1;
                        continue;
                    }
                    if (try workbench.handleStatusbarKey(event)) continue;
                    if (workbench.handleSearchEditorKey(event)) {
                        needs_render = true;
                        continue;
                    }

                    const modal_host = helix_runtime.host orelse vim_runtime.host;
                    if (modal_host) |host| {
                        const editor_focused = workbench.focus == .editor;
                        const normal_tab = if (workbench.activeTab()) |tab| !tab.isDiff() and !tab.isImage() and tab.markdown_preview == null and tab.terminal_input == null else false;
                        if (!workbench.is_pasting and editor_focused and normal_tab and
                            dispatchExtensionKey(workbench, host, event))
                        {
                            needs_render = true;
                            continue;
                        }
                    }
                    if (try workbench.handleGlobalKey(event)) continue;

                    switch (try workbench.handleTabKey(event)) {
                        .quit => return,
                        .handled => continue,
                        .unhandled => {},
                    }
                    if (try workbench.handleBreadcrumbsKey(event)) continue;
                    if (workbench.handleWatermarkKey(event)) continue;

                    const current = workbench.activeTab() orelse continue;
                    if (current.markdown_preview) |preview| {
                        preview.handleKey(event);
                        continue;
                    }
                    if (current.isImage()) {
                        switch (current.handleImageKey(event)) {
                            .changed => {
                                workbench.refreshStatus();
                                needs_render = true;
                            },
                            .open_text => {
                                try workbench.openActiveImageAsText();
                                needs_render = true;
                            },
                            .none => {},
                        }
                        continue;
                    }
                    if (current.isDiff()) {
                        if (current.handleDiffKey(event)) needs_render = true;
                        continue;
                    }
                    if (!workbench.is_pasting and workbench.focus == .editor and !event.mods.ctrl and !event.mods.alt) {
                        if (extension_host) |ext| {
                            const suggest_open = if (current.controllers) |c| c.suggest.isOpen() or c.suggest.hasSnippetSession() else false;
                            if (!suggest_open and current.view.ghost_text.isVisible()) {
                                switch (event.key) {
                                    .tab => if (try ext.inline_completions.accept()) {
                                        needs_render = true;
                                        continue;
                                    },
                                    .escape => {
                                        ext.inline_completions.dismiss();
                                        needs_render = true;
                                        continue;
                                    },
                                    else => {},
                                }
                            }
                        }
                    }
                    if (try current.handleEditorKey(event, &workbench.is_pasting, now_ms, null)) return;
                },
                .mouse => |*event| {
                    // Only motion re-resolves the whole workbench: a press or
                    // release keeps the shape the last move established, so a
                    // click on a row does not flicker back to the arrow.
                    if (event.kind == .move) workbench.beginMousePointer();
                    if (workbench.handleDialogMouse(event)) {
                        if (workbench.shouldQuit()) return;
                        continue;
                    }
                    if (workbench.context_menu_service.handleMouse(event, &workbench.pointer)) continue;
                    if (workbench.handleBreadcrumbPopupMouse(event)) continue;
                    if (workbench.handleTabDragMouse(event)) continue;
                    if (workbench.handleQuickAccessMouse(event)) continue;
                    if (workbench.handleSashMouse(event)) continue;
                    if (workbench.handleStatusbarMouse(event)) continue;
                    if (workbench.handlePanelMouse(event)) continue;
                    if (workbench.handleSidebarMouse(event)) {
                        sidebar_event_count += 1;
                        continue;
                    }
                    if (workbench.handleTabMouse(event)) continue;
                    if (workbench.handleTerminalMouse(event)) continue;
                    if (workbench.handleSearchEditorMouse(event)) {
                        needs_render = true;
                        continue;
                    }

                    // The editor pane resolves text/pointer/resize shapes from
                    // the surface's style tree before the event is routed.
                    workbench.updateMousePointer(event.*);
                    var target = workbench.editorMouseEvent(event.*) orelse continue;
                    const current = target.tab;
                    const adjusted = &target.event;
                    if (current.isImage()) {
                        const focus_gained = workbench.focus != .editor;
                        if (event.kind == .down) workbench.focusEditor();
                        switch (current.handleImageMouse(adjusted, focus_gained)) {
                            .changed => {
                                workbench.refreshStatus();
                                needs_render = true;
                            },
                            .open_text => {
                                try workbench.openActiveImageAsText();
                                needs_render = true;
                            },
                            .none => {},
                        }
                        continue;
                    }
                    if (event.kind == .down) {
                        workbench.focusEditor();
                        const modal_host = helix_runtime.host orelse vim_runtime.host;
                        if (modal_host) |host| host.resetKeyInput();
                    }
                    if (current.markdown_preview) |preview| {
                        if (preview.handleMouse(adjusted, now_ms)) |line| {
                            try workbench.showMarkdownSource();
                            if (workbench.activeTab()) |source| {
                                try source.editor.setSelection(Range.init(line, 1, line, 1));
                                _ = source.editor.revealLine(line, .CenterIfOutsideViewport);
                            }
                        }
                        if (event.kind == .move) workbench.leaveEditorHover();
                        needs_render = true;
                        continue;
                    }
                    if (current.isDiff()) {
                        _ = current.handleDiffMouse(adjusted) catch false;
                        if (event.kind == .down) needs_render = true;
                        continue;
                    }
                    const tab_controllers = current.controllers orelse blk: {
                        try current.ensureControllers();
                        break :blk current.controllers.?;
                    };
                    handleMouseEvent(
                        current.view,
                        tab_controllers.hover,
                        tab_controllers.find,
                        tab_controllers.suggest,
                        current.editor,
                        adjusted,
                    ) catch |err| {
                        current.editor.setMessage("mouse failed: {s}", .{@errorName(err)});
                    };
                    // Deliver the click/drag caret change before the next key
                    // reaches an extension that follows the selection.
                    if (extension_host) |ext| {
                        if (ext.pump()) needs_render = true;
                    }
                },
            }
        }
        terminal_host.consume(batch.decoded.consumed);

        // Explorer wheel/hover/selection events do not change the active
        // editor. New/activated tabs and layout/focus changes already dirty
        // their views, so only a batch containing a non-Explorer event needs
        // the forced editor refresh.
        if (events.items.len == 0 or sidebar_event_count < events.items.len) {
            if (workbench.activeTab()) |current| {
                if (!current.isImage()) {
                    current.onEditorChanged(time_compat.milliTimestamp());
                    workbench.onSearchEditorChanged();
                    try current.refresh();
                } else {
                    try current.refresh();
                }
            }
        }
        workbench.refreshStatus();
        try tui.hideCursor(out);
        needs_render = false;
        try terminal_host.render();
    }
}

/// Routes one editor keydown through the built-in extension key handler.
///
/// Upstream's text area fires `CodeEditorWidget.onKeyDown` to the editor
/// contributions before keybinding dispatch. In the TUI the extension key
/// handler is that dispatch step, so the hover contribution must observe the
/// key first: a Vim cursor motion then dismisses a hover opened with `gh`
/// instead of leaving it behind. A focused editor widget (hover, find, suggest,
/// sticky scroll) owns the keyboard, so the extension handler is skipped and
/// the key falls through to the view's focused-node dispatch.
///
/// Returns true when the extension consumed the key.
fn dispatchExtensionKey(workbench: *Workbench, host: anytype, event: *ui.KeyEvent) bool {
    if (workbench.notifyEditorKeyDown(event)) return false;
    return host.dispatchKey(event);
}

/// Routes one mouse event through the view. The view owns hit testing, focus,
/// caret placement, drag selection, click synthesis and wheel scrolling.
fn handleMouseEvent(
    view: *View,
    hover: *ContentHoverController,
    find: *FindController,
    suggest: ?*SuggestController,
    editor: *Editor,
    event: *input.MouseEvent,
) !void {
    if (event.kind != .move) {
        editor.clearMessage();
    }

    const target = try view.mouseTargetAt(event.x, event.y);
    if (event.kind == .move) {
        view.setGlyphHover(target);
    } else {
        view.clearGlyphHover();
    }
    const hover_event = hoverTypes.EditorMouseEvent{
        .target = target,
        .x = event.x,
        .y = event.y,
        .mods = event.mods,
        .button = event.button,
    };
    switch (event.kind) {
        .down => hover.onMouseDown(hover_event),
        .up => hover.onMouseUp(),
        .move => switch (target.type) {
            // The gutter and overlay widgets are inside the editor area in
            // VS Code, so they produce a mouse move (with no anchor) and the
            // sticky hover gets its grace period. The status row is outside
            // the editor, so it is a mouse leave.
            .content_text, .content_empty, .content_widget, .gutter_line_numbers, .gutter_glyph_margin, .gutter_line_decorations, .gutter_view_zone, .content_view_zone, .scrollbar, .overview_ruler, .overlay_widget => hover.onMouseMove(hover_event),
            .status, .unknown, .textarea, .outside_editor => hover.onEditorMouseLeave(hover_event),
        },
        .wheel, .click => {},
    }

    if (event.kind == .down and target.type != .content_widget) {
        if (suggest) |controller| controller.cancel();
    }
    const top_before = editor.topViewLine();
    if (try view.dispatchMouse(event)) find.onEditorChanged();
    if (event.kind == .wheel and !event.default_prevented) {
        hover.onEditorScrollChanged(editor.topViewLine() != top_before);
    }
}

fn viewTextHeight(context: *anyopaque) usize {
    const view: *View = @ptrCast(@alignCast(context));
    return view.editor.textHeight();
}

fn viewVisibleRowOf(context: *anyopaque, position: Position) ?usize {
    const view: *View = @ptrCast(@alignCast(context));
    return view.visibleRowOf(position);
}

fn viewRequestFrame(_: *anyopaque) void {
    // The event loop refreshes and renders after every input batch and after
    // any hover timer fired, so no extra frame request is needed.
}

fn viewFocusEditor(context: *anyopaque) void {
    const view: *View = @ptrCast(@alignCast(context));
    view.focusEditor();
}

fn viewHasEditorFocus(context: *anyopaque) bool {
    const view: *View = @ptrCast(@alignCast(context));
    return view.hasEditorFocus();
}

fn viewSetWordDecorations(context: *anyopaque, decorations: []const editorBrowser.Decoration) void {
    const view: *View = @ptrCast(@alignCast(context));
    view.setWordHighlights(decorations) catch {};
}

fn setHoverModelDecoration(context: *anyopaque, range: ?Range) void {
    if (range) |value| {
        const decorations = [_]editorBrowser.Decoration{
            .{ .range = value, .kind = .hover_highlight },
        };
        View.ModelDecorationSink.set(context, &decorations);
    } else {
        View.ModelDecorationSink.set(context, &.{});
    }
}

fn viewSetHoverDecoration(context: *anyopaque, range: ?Range) void {
    const view: *View = @ptrCast(@alignCast(context));
    if (range) |value| {
        view.setHoverDecorations(&[_]editorBrowser.Decoration{
            .{ .range = value, .kind = .hover_highlight },
        }) catch {};
    } else {
        view.setHoverDecorations(&.{}) catch {};
    }
}

fn viewModelColumnAtViewLineStart(context: *anyopaque, position: Position) usize {
    const view: *View = @ptrCast(@alignCast(context));
    const view_position = view.editor.viewPositionOfModelPosition(position);
    const data = view.editor.viewLineData(view_position.lineNumber) catch return 1;
    return view.editor.modelColumnOfViewPosition(view_position.lineNumber, data.minColumn);
}

/// Hides the hardware cursor when it has no cell, otherwise moves it to the
/// view's caret and shows it.
fn syncCursor(out: *Io.Writer, view: *View) !void {
    if (view.cursorCell()) |cell| {
        try tui.moveCursor(out, .{ .row = cell.row + 1, .col = cell.col + 1 });
        try tui.showCursor(out);
    } else {
        try tui.hideCursor(out);
    }
}

fn runPreview(allocator: std.mem.Allocator, io: Io, out: *Io.Writer, editor: *Editor, initial_size: tui.Size, json_client: ?*json_language.Client) !void {
    var size = initial_size;
    try tui.hideCursor(out);
    defer tui.showCursor(out) catch {};

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.setScrollbarWidth(0);
    try setPreviewStatus(editor, view);
    // The preview owns the whole terminal surface, so it can emit OSC 22
    // directly from `View.render`.
    view.setPointerShapes(true);

    try view.renderAnsi(out);
    try out.flush();

    var input_buffer = try ArrayList(u8).initCapacity(allocator, 256);
    defer input_buffer.deinit();

    while (true) {
        const ready = try tui.pollInput(250);
        if (json_client) |client| {
            if (client.dispatchResponses(false)) {
                try setPreviewStatus(editor, view);
                try view.renderAnsi(out);
                try out.flush();
            }
        }

        if (try tui.resizedSize()) |new_size| {
            size = new_size;
            editor.setViewport(size.width, size.height);
            view.invalidate();
            try tui.clearScreen(out);
            try view.renderAnsi(out);
            try out.flush();
            continue;
        }

        if (!ready) continue;

        const bytes = try tui.readFd(io, 0, &input_buffer);
        const decoded = try ui.input.decodeWithRemainder(allocator, bytes);
        var events = decoded.items;
        defer events.deinit(allocator);
        const consumed = decoded.consumed;

        var redraw = false;
        for (events.items) |*item| {
            switch (item.*) {
                .focus => {},
                .key => |event| {
                    if (handlePreviewKey(editor, view, event)) |changed| {
                        if (changed) redraw = true;
                    } else return;
                },
                .mouse => |event| {
                    if (event.kind == .move) {
                        const shape = view.pointerAt(event.x, event.y) catch .default;
                        if (view.setPointer(shape)) redraw = true;
                    }
                    if (handlePreviewMouse(editor, view, event)) redraw = true;
                },
            }
        }
        if (consumed < input_buffer.items.len) {
            const remainder = input_buffer.items.len - consumed;
            std.mem.copyForwards(u8, input_buffer.items[0..remainder], input_buffer.items[consumed..]);
            input_buffer.shrinkRetainingCapacity(remainder);
        } else {
            input_buffer.clearRetainingCapacity();
        }
        if (redraw) {
            try view.renderAnsi(out);
            try out.flush();
        }
    }
}

/// Fills the view's fallback status row with the read-only preview text.
fn setPreviewStatus(editor: *Editor, view: *View) !void {
    const position = editor.modelCursorPosition();
    var status_buf: [1024]u8 = undefined;
    const status = std.fmt.bufPrint(
        &status_buf,
        " {s}{s}  Ln {d}, Col {d}  {s}  PREVIEW  wheel/Up/Down scroll  Ctrl-Q quit{s}{s}",
        .{
            editor.path,
            if (editor.isDirty()) "*" else "",
            position.lineNumber,
            position.column,
            editor.languageId(),
            if (editor.message().len > 0) "  " else "",
            editor.message(),
        },
    ) catch status_buf[0..0];
    view.setStatusText(status, "");
    try view.refresh();
}

/// Returns null when the key asked to quit, otherwise whether the view moved.
fn handlePreviewKey(editor: *Editor, view: *View, event: input.KeyEvent) ?bool {
    const ctrl_q = event.mods.ctrl and switch (event.key) {
        .char => |ch| ch == 'q',
        else => false,
    };
    if (ctrl_q) return null;
    if (event.mods.ctrl or event.mods.alt) return false;

    const page = editor.textHeight();
    const maximum = editor.viewLineCount() -| page;
    const changed = switch (event.key) {
        .up => editor.scrollViewLines(-1),
        .down => editor.scrollViewLines(1),
        .page_up => editor.scrollViewLines(-@as(isize, @intCast(page))),
        .page_down => editor.scrollViewLines(@intCast(page)),
        .home => editor.setTopViewLine(1),
        .end => editor.setTopViewLine(maximum + 1),
        else => false,
    };
    if (changed) view.refresh() catch return false;
    return changed;
}

fn handlePreviewMouse(editor: *Editor, view: *View, event: ui.MouseEvent) bool {
    if (event.kind != .wheel or event.default_prevented) return false;
    if (event.y >= editor.textHeight()) return false;
    var changed = false;
    if (event.delta_x != 0) changed = editor.scrollColumns(event.delta_x) or changed;
    if (event.delta_y != 0) changed = editor.scrollViewLines(event.delta_y) or changed;
    if (!changed) return false;
    view.refresh() catch return false;
    return true;
}

fn isCtrlQ(event: input.KeyEvent) bool {
    return editorInputDispatch.isCtrlQ(event);
}

fn requestViewRender(context: ?*anyopaque) void {
    const view: *View = @ptrCast(@alignCast(context orelse return));
    view.invalidate();
}

fn setViewDecorations(context: ?*anyopaque, decorations: []const editorBrowser.Decoration) void {
    const view: *View = @ptrCast(@alignCast(context orelse return));
    view.setDecorations(decorations) catch {};
}

fn dispatch(editor: *Editor, event: input.KeyEvent, is_pasting: *bool) bool {
    return editorInputDispatch.dispatch(editor, event, is_pasting);
}

fn disableHelixForVim(context: *anyopaque) void {
    const helix: *HelixRuntime = @ptrCast(@alignCast(context));
    if (helix.isEnabled()) helix.setEnabledPersistent(false) catch {};
}

fn disableVimForHelix(context: *anyopaque) void {
    const vim: *VimRuntime = @ptrCast(@alignCast(context));
    if (vim.isEnabled()) vim.setEnabledPersistent(false) catch {};
}

test "app: q inserts text" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "hello", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var pasting = false;
    const q_event = input.KeyEvent{ .key = .{ .text = "q" } };
    try std.testing.expect(!dispatch(editor, q_event, &pasting));
    const line = try editor.model.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("qhello", line.items);
    try std.testing.expect(editor.isDirty());
}

test "app: move lines and line comment shortcuts" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "a\nb", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var pasting = false;
    const alt_down = input.KeyEvent{ .key = .down, .mods = .{ .alt = true } };
    try std.testing.expect(!dispatch(editor, alt_down, &pasting));
    const first = try editor.model.getLineContent(1);
    defer first.deinit();
    try std.testing.expectEqualStrings("b", first.items);

    const ctrl_slash = input.KeyEvent{ .key = .{ .char = '/' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(!dispatch(editor, ctrl_slash, &pasting));
    const second = try editor.model.getLineContent(2);
    defer second.deinit();
    try std.testing.expectEqualStrings("// a", second.items);

    const ctrl_l = input.KeyEvent{ .key = .{ .char = 'l' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(!dispatch(editor, ctrl_l, &pasting));
    try std.testing.expectEqual(@as(usize, 2), editor.modelSelection().endLineNumber);
}

test "app: folding shortcuts fold and unfold the current region" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(
        allocator,
        io,
        "class A {\n  void f() {\n    x();\n  }\n}",
        "test.zig",
        40,
        10,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var pasting = false;
    const ctrl_k = input.KeyEvent{ .key = .{ .char = 'k' }, .mods = .{ .ctrl = true } };
    const ctrl_l = input.KeyEvent{ .key = .{ .char = 'l' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(!dispatch(editor, ctrl_k, &pasting));
    try std.testing.expect(!dispatch(editor, ctrl_l, &pasting));
    try std.testing.expectEqual(@as(usize, 2), editor.viewLineCount());

    try std.testing.expect(!dispatch(editor, ctrl_k, &pasting));
    try std.testing.expect(!dispatch(editor, ctrl_l, &pasting));
    try std.testing.expectEqual(@as(usize, 5), editor.viewLineCount());
}

test "app: jump to bracket shortcut" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "(a)", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var pasting = false;
    const ctrl_backslash = input.KeyEvent{ .key = .{ .char = '\\' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(!dispatch(editor, ctrl_backslash, &pasting));
    try std.testing.expectEqual(@as(usize, 3), editor.modelCursorPosition().column);
}

test "app: indent lines shortcut" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "a", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var pasting = false;
    const ctrl_bracket = input.KeyEvent{ .key = .{ .char = ']' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(!dispatch(editor, ctrl_bracket, &pasting));
    const line = try editor.model.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("    a", line.items);
}

test "app: typing an open bracket auto-closes it" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var pasting = false;
    const open_paren = input.KeyEvent{ .key = .{ .text = "(" } };
    try std.testing.expect(!dispatch(editor, open_paren, &pasting));

    const value = try editor.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("()", value.items);
    try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().column);
}

// Regression: the decoder used to drop 0x06, so Ctrl-F never reached the app.
test "app: Ctrl-F opens the find bar through the byte decoder" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "alpha beta\nalpha gamma",
        "test.txt",
        100,
        8,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const find = try FindController.init(allocator, editor, .{
        .context = view,
        .set = setViewDecorations,
    });
    defer find.deinit();
    find.widget().layout_context = view;
    find.widget().on_layout = requestViewRender;
    // Keep the search string empty regardless of the seeding default; this
    // test covers the Ctrl-F byte decoder and the widget's open/close state.
    find.setSeedSearchStringFromSelection(.never);
    editor.setFindController(find, FindController.startFromContext);
    try view.addOverlayWidget(find.widget().interface());

    const hover = try ContentHoverController.init(allocator, editor.model, &.{}, .{}, .{
        .context = view,
        .text_height = viewTextHeight,
        .visible_row_of = viewVisibleRowOf,
        .request_frame = viewRequestFrame,
        .focus_editor = viewFocusEditor,
        .set_hover_decoration = viewSetHoverDecoration,
    });
    defer hover.deinit();

    var word_sink = View.ModelDecorationSink{ .model = editor.model, .owner = 3 };
    const word_highlighter = try WordHighlighterContribution.init(allocator, editor, .{
        .context = view,
        .decoration_context = word_sink.context(),
        .has_text_focus = viewHasEditorFocus,
        .set_decorations = View.ModelDecorationSink.set,
        .request_frame = viewRequestFrame,
    }, .{});
    defer word_highlighter.deinit();

    var pasting = false;
    var open_events = try ui.input.decodeKeys(allocator, "\x06");
    defer open_events.deinit(allocator);
    for (open_events.items) |*event| {
        try std.testing.expect(!try handleKeyEvent(view, hover, word_highlighter, find, null, editor, event, &pasting, 0, null));
    }

    try std.testing.expect(find.isOpen());
    try std.testing.expectEqualStrings("", find.state.search_string);

    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const open_row = try view.surface.grid().rowText(allocator, 0);
    defer allocator.free(open_row);
    try std.testing.expect(std.mem.indexOf(u8, open_row, "Find") != null);
    try std.testing.expect(view.surface.document().focusedElement() != null);

    // Escape is handled by the widget, not inserted into the document.
    var close_events = try ui.input.decodeKeys(allocator, "\x1b");
    defer close_events.deinit(allocator);
    for (close_events.items) |*event| {
        try std.testing.expect(!try handleKeyEvent(view, hover, word_highlighter, find, null, editor, event, &pasting, 0, null));
    }
    try std.testing.expect(!find.isOpen());

    try view.refresh();
    try view.renderAnsi(&out.writer);
    const closed_row = try view.surface.grid().rowText(allocator, 0);
    defer allocator.free(closed_row);
    try std.testing.expect(std.mem.indexOf(u8, closed_row, "Find") == null);
}

test "app: the word under the caret highlights its occurrences" {
    const allocator = std.testing.allocator;
    defer word_character_classifier.freeWordClassifierCache();
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "word word word other", "test.txt", 60, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var word_sink = View.ModelDecorationSink{ .model = editor.model, .owner = 3 };
    const word_highlighter = try WordHighlighterContribution.init(allocator, editor, .{
        .context = view,
        .decoration_context = word_sink.context(),
        .has_text_focus = viewHasEditorFocus,
        .set_decorations = View.ModelDecorationSink.set,
        .request_frame = viewRequestFrame,
    }, .{});
    defer word_highlighter.deinit();

    word_highlighter.onEditorChanged(0);
    try std.testing.expect(word_highlighter.onTick(50));

    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    for ([_]usize{ 0, 5, 10 }) |offset| {
        const background = ui.cell.unpackColor(grid.bg[grid.index(gutter + offset, 0)]);
        try std.testing.expectEqual(@as(u8, 71), background.r);
        try std.testing.expectEqual(@as(u8, 71), background.g);
        try std.testing.expectEqual(@as(u8, 71), background.b);
    }
    // `other` is not an occurrence of `word`.
    const other = ui.cell.unpackColor(grid.bg[grid.index(gutter + 16, 0)]);
    try std.testing.expectEqual(@as(u8, 32), other.r);

    // Move to `other`: the old highlights are replaced.
    try editor.setCursorPosition(Position.init(1, 17));
    word_highlighter.onEditorChanged(100);
    try std.testing.expect(word_highlighter.onTick(150));
    try view.refresh();
    try view.renderAnsi(&out.writer);

    const moved = ui.cell.unpackColor(view.surface.grid().bg[view.surface.grid().index(gutter + 0, 0)]);
    try std.testing.expectEqual(@as(u8, 32), moved.r);
}

test "app: hover coordinate host uses the wrapped segment start" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "aaaa bbbb cccc dddd", "test.zig", 20, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    try std.testing.expectEqual(@as(usize, 1), viewModelColumnAtViewLineStart(view, Position.init(1, 3)));
    // The final word wraps to the second view line. The gutter width decides
    // where the break lands, so derive the expected column from the view line
    // data instead of hard-coding a text-area width.
    const wrapped = editor.viewPositionOfModelPosition(Position.init(1, 18));
    try std.testing.expect(wrapped.lineNumber > 1);
    const wrapped_data = try editor.viewLineData(wrapped.lineNumber);
    const expected_column = editor.modelColumnOfViewPosition(wrapped.lineNumber, wrapped_data.minColumn);
    try std.testing.expectEqual(expected_column, viewModelColumnAtViewLineStart(view, Position.init(1, 18)));
}

test "app: hovering a word shows the rendered markdown hover" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "const value = 42;", "test.zig", 60, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var tui_provider = TuiHoverProvider.init(allocator);
    defer tui_provider.deinit();
    const providers = [_]languages.HoverProvider{tui_provider.interface()};
    var participant = MarkdownHoverParticipant.init(allocator, editor.model, &providers);
    defer participant.deinit();
    const participants = [_]hoverTypes.IEditorHoverParticipant{participant.interface()};

    const hover = try ContentHoverController.init(allocator, editor.model, &participants, .{}, .{
        .context = view,
        .text_height = viewTextHeight,
        .visible_row_of = viewVisibleRowOf,
        .request_frame = viewRequestFrame,
        .focus_editor = viewFocusEditor,
        .set_hover_decoration = viewSetHoverDecoration,
        .coordinates = .{
            .context = view,
            .model_column_at_view_line_start = viewModelColumnAtViewLineStart,
        },
    });
    defer hover.deinit();
    try view.addContentWidget(hover.widget().contentWidget());

    const target = editorBrowser.MouseTarget{
        .type = .content_text,
        .position = Position.init(1, 7),
        .range = Range.init(1, 7, 1, 7),
        .mouse_column = 10,
    };
    const event = hoverTypes.EditorMouseEvent{ .target = target, .x = 9, .y = 0 };
    hover.onMouseMove(event);
    try std.testing.expect(!hover.isVisible());

    const now = time_compat.milliTimestamp();
    _ = hover.onTick(now + 1000); // async half of the hover delay
    _ = hover.onTick(now + 2000); // sync half
    try std.testing.expect(hover.isVisible());

    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const box = view.terminal_view_host.viewRef().contentWidgets().entries.items[0];
    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(u32, '╭'), grid.cluster[grid.index(box.left, box.top)]);
    try std.testing.expectEqual(@as(u32, '╯'), grid.cluster[grid.index(box.left + box.width - 1, box.top + box.height - 1)]);

    var found_word = false;
    for (0..5) |row| {
        const text = try view.surface.grid().rowText(allocator, row);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "value") != null) found_word = true;
    }
    try std.testing.expect(found_word);

    // The word range is highlighted below the hover (the dark-theme
    // `hoverHighlight` composited over the editor background).
    const highlighted = ui.cell.unpackColor(grid.bg[grid.index(editor.gutterWidth() + 6, 0)]);
    try std.testing.expectEqual(@as(u8, 32), highlighted.r);
    try std.testing.expectEqual(@as(u8, 42), highlighted.g);
    try std.testing.expectEqual(@as(u8, 52), highlighted.b);

    // Leaving the text hides the hover and clears the highlight.
    var leave = event;
    leave.target.type = .gutter_line_numbers;
    hover.onEditorMouseLeave(leave);
    try std.testing.expect(!hover.isVisible());
    try view.refresh();
    try view.renderAnsi(&out.writer);
    const cleared = ui.cell.unpackColor(view.surface.grid().bg[view.surface.grid().index(editor.gutterWidth() + 6, 0)]);
    // Back to the current-line background, not the hover highlight.
    try std.testing.expectEqual(@as(u8, 32), cleared.r);
    try std.testing.expectEqual(@as(u8, 32), cleared.g);
    try std.testing.expectEqual(@as(u8, 36), cleared.b);

    // Show it again, click inside the box and close it with Escape. The click
    // focuses the hover, Escape gives the keyboard back to the editor.
    hover.onMouseMove(event);
    _ = hover.onTick(time_compat.milliTimestamp() + 3000);
    _ = hover.onTick(time_compat.milliTimestamp() + 4000);
    try std.testing.expect(hover.isVisible());
    try view.refresh();
    try view.renderAnsi(&out.writer);

    const entry = view.terminal_view_host.viewRef().contentWidgets().entries.items[0];
    var down = ui.MouseEvent{
        .kind = .down,
        .x = entry.left + 2,
        .y = entry.top + 1,
        .button = .left,
    };
    _ = try view.dispatchMouse(&down);
    var release = down;
    release.kind = .up;
    _ = try view.dispatchMouse(&release);
    try std.testing.expect(view.surface.document().focusedElement() != null);
    try std.testing.expect(hover.isFocused());

    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(view.dispatchKey(&escape));
    try std.testing.expect(!hover.isVisible());
    try std.testing.expect(view.surface.document().focusedElement() == null);
}

test "app: vim motions reach the hover before the extension key handler" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hover-vim.txt", .data = "const value = 1;\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(io, "hover-vim.txt", &path_buffer);

    const workbench_window = try TestWindow.init(allocator, io, &.{path_buffer[0..path_len]}, 80, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    const tab = workbench.activeTab().?;
    try tab.editor.setCursorPosition(Position.init(1, 7));
    try std.testing.expect(try workbench.showHover());
    try std.testing.expect(tab.controllers.?.hover.isVisible());

    const FakeHost = struct {
        calls: usize = 0,

        fn dispatchKey(self: *@This(), event: *ui.KeyEvent) bool {
            self.calls += 1;
            return switch (event.key) {
                .char => |char| char == 'j',
                else => false,
            };
        }
    };
    var host = FakeHost{};
    var motion = ui.KeyEvent{ .key = .{ .char = 'j' } };

    // `gh` opened this hover from the keyboard. The motion key reaches the
    // hover contribution before Vim, so the popup disappears while Vim still
    // receives the key and moves the cursor.
    try std.testing.expect(dispatchExtensionKey(workbench, &host, &motion));
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    try std.testing.expect(!tab.controllers.?.hover.isVisible());

    // A focused hover owns the keyboard: the extension handler is skipped and
    // the normal view dispatch gives the key to the hover box.
    try std.testing.expect(try workbench.showHover());
    try std.testing.expect(try workbench.showHover());
    try std.testing.expect(tab.controllers.?.hover.isFocused());
    host.calls = 0;
    try std.testing.expect(!dispatchExtensionKey(workbench, &host, &motion));
    try std.testing.expectEqual(@as(usize, 0), host.calls);
    try std.testing.expect(tab.controllers.?.hover.isVisible());
}

test "app: hover renders a GFM table and task list" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "value here", "test.zig", 72, 80);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const TextModel = @import("../vs/editor/common/model/textModel.zig").TextModel;
    const CancellationToken = @import("../vs/base/common/cancellation.zig").CancellationToken;
    const Provider = struct {
        contents: [1]languages.IMarkdownString = .{.{ .value =
        \\| name | value |
        \\|---|---|
        \\| alpha | 1 |
        \\
        \\- [x] done
        \\
        \\> A quote that wraps in the hover box should keep its left border on both rows.
        \\
        \\```zig
        \\const answer = 42;
        \\```
        }},
        range: Range = .{ .startLineNumber = 1, .startColumn = 1, .endLineNumber = 1, .endColumn = 6 },

        fn provide(
            context: *anyopaque,
            _: *TextModel,
            _: Position,
            _: CancellationToken,
            _: ?*const languages.HoverContext,
        ) anyerror!?languages.Hover {
            const self: *@This() = @ptrCast(@alignCast(context));
            return .{ .contents = &self.contents, .range = self.range };
        }
    };
    var provider = Provider{};
    const providers = [_]languages.HoverProvider{.{
        .context = &provider,
        .provide_hover = Provider.provide,
    }};

    var participant = MarkdownHoverParticipant.init(allocator, editor.model, &providers);
    defer participant.deinit();
    const participants = [_]hoverTypes.IEditorHoverParticipant{participant.interface()};

    const hover = try ContentHoverController.init(allocator, editor.model, &participants, .{}, .{
        .context = view,
        .text_height = viewTextHeight,
        .visible_row_of = viewVisibleRowOf,
        .request_frame = viewRequestFrame,
        .focus_editor = viewFocusEditor,
        .set_hover_decoration = viewSetHoverDecoration,
        .coordinates = .{
            .context = view,
            .model_column_at_view_line_start = viewModelColumnAtViewLineStart,
        },
    });
    defer hover.deinit();
    try view.addContentWidget(hover.widget().contentWidget());

    const target = editorBrowser.MouseTarget{
        .type = .content_text,
        .position = Position.init(1, 3),
        .range = Range.init(1, 1, 1, 6),
        .mouse_column = 3,
    };
    hover.onMouseMove(.{ .target = target, .x = 2, .y = 0 });
    const now = time_compat.milliTimestamp();
    _ = hover.onTick(now + 1000);
    _ = hover.onTick(now + 2000);
    try std.testing.expect(hover.isVisible());

    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const box = view.terminal_view_host.viewRef().contentWidgets().entries.items[0];
    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(u32, '╭'), grid.cluster[grid.index(box.left, box.top)]);
    try std.testing.expectEqual(@as(u32, '╯'), grid.cluster[grid.index(box.left + box.width - 1, box.top + box.height - 1)]);

    var found_table = false;
    var found_cell = false;
    var found_task = false;
    var found_quote_continuation = false;
    const keyword_color = ui.cell.packColor(.{ .r = 197, .g = 134, .b = 192 });
    var found_keyword = false;
    for (grid.fg) |foreground| {
        if (foreground == keyword_color) found_keyword = true;
    }
    for (0..grid.rows) |row| {
        const text = try grid.rowText(allocator, row);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "┌") != null) found_table = true;
        if (std.mem.indexOf(u8, text, "alpha") != null) found_cell = true;
        if (std.mem.indexOf(u8, text, "[x] done") != null) found_task = true;
        if (std.mem.indexOf(u8, text, "both rows") != null and
            std.mem.indexOf(u8, text, "││") != null)
        {
            found_quote_continuation = true;
        }
    }
    try std.testing.expect(found_table);
    try std.testing.expect(found_cell);
    try std.testing.expect(found_task);
    try std.testing.expect(found_quote_continuation);
    try std.testing.expect(found_keyword);

    hover.hideContentHover();
    try view.refresh();
}

test "app: long hover content scrolls without moving the editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "value\nvalue\nvalue\nvalue\nvalue\nvalue\nvalue\nvalue\nvalue\nvalue",
        "test.zig",
        40,
        10,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const LongProvider = struct {
        contents: [1]languages.IMarkdownString = undefined,

        fn provide(context: *anyopaque, _: *@import("../vs/editor/common/model/textModel.zig").TextModel, _: Position, _: @import("../vs/base/common/cancellation.zig").CancellationToken, _: ?*const languages.HoverContext) anyerror!?languages.Hover {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.contents[0] = .{ .value = "one\n\ntwo\n\nthree\n\nfour\n\nfive\n\nsix\n\nseven\n\neight\n\nnine\n\nten" };
            return .{ .contents = &self.contents, .range = Range.init(1, 1, 1, 5) };
        }
    };
    var long_provider = LongProvider{};
    const providers = [_]languages.HoverProvider{.{
        .context = &long_provider,
        .provide_hover = LongProvider.provide,
    }};

    var participant = MarkdownHoverParticipant.init(allocator, editor.model, &providers);
    defer participant.deinit();
    const participants = [_]hoverTypes.IEditorHoverParticipant{participant.interface()};
    const hover = try ContentHoverController.init(allocator, editor.model, &participants, .{}, .{
        .context = view,
        .text_height = viewTextHeight,
        .visible_row_of = viewVisibleRowOf,
        .request_frame = viewRequestFrame,
        .focus_editor = viewFocusEditor,
        .set_hover_decoration = viewSetHoverDecoration,
    });
    defer hover.deinit();
    try view.addContentWidget(hover.widget().contentWidget());

    const target = editorBrowser.MouseTarget{
        .type = .content_text,
        .position = Position.init(1, 1),
        .range = Range.init(1, 1, 1, 1),
        .mouse_column = 1,
    };
    hover.onMouseMove(.{ .target = target, .x = 3, .y = 0 });
    _ = hover.onTick(time_compat.milliTimestamp() + 1000);
    _ = hover.onTick(time_compat.milliTimestamp() + 2000);
    try std.testing.expect(hover.isVisible());

    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.renderAnsi(&out.writer);

    const widget = hover.widget().widget;
    try std.testing.expect(widget.content_rows > widget.visible_rows);
    try std.testing.expect(widget.show_scrollbar);

    const top_before = editor.topViewLine();
    const entry = view.terminal_view_host.viewRef().contentWidgets().entries.items[0];
    var wheel = ui.MouseEvent{
        .kind = .wheel,
        .x = entry.left + 3,
        .y = entry.top + 2,
        .delta_y = 1,
    };
    _ = try view.dispatchMouse(&wheel);
    try std.testing.expect(wheel.default_prevented);
    try std.testing.expect(widget.scroll_top > 0);
    try std.testing.expectEqual(top_before, editor.topViewLine());
}

test "app: decoded clicks, drags and wheel reach the editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text =
        "line0\nline1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9";
    const editor = try Editor.createFromText(allocator, io, text, "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    const find = try FindController.init(allocator, editor, .{
        .context = view,
        .set = setViewDecorations,
    });
    defer find.deinit();
    try view.addOverlayWidget(find.widget().interface());

    const hover = try ContentHoverController.init(allocator, editor.model, &.{}, .{}, .{
        .context = view,
        .text_height = viewTextHeight,
        .visible_row_of = viewVisibleRowOf,
        .request_frame = viewRequestFrame,
        .focus_editor = viewFocusEditor,
        .set_hover_decoration = viewSetHoverDecoration,
    });
    defer hover.deinit();

    const gutter = editor.gutterWidth();
    var press_buf: [40]u8 = undefined;
    var release_buf: [40]u8 = undefined;
    const press = try std.fmt.bufPrint(&press_buf, "\x1b[<0;{d};2M", .{gutter + 2});
    const release = try std.fmt.bufPrint(&release_buf, "\x1b[<0;{d};2m", .{gutter + 2});

    var buffer: [128]u8 = undefined;
    const events = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ press, release });
    var items = try ui.input.decode(allocator, events);
    defer items.deinit(allocator);
    for (items.items) |*item| {
        switch (item.*) {
            .key, .focus => return error.TestUnexpectedResult,
            .mouse => |*mouse| try handleMouseEvent(view, hover, find, null, editor, mouse),
        }
    }

    try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().lineNumber);
    try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().column);

    // Drag from the start of line 3 five cells to the right.
    var drag_buf: [64]u8 = undefined;
    const drag = try std.fmt.bufPrint(
        &drag_buf,
        "\x1b[<0;{d};3M\x1b[<32;{d};3M\x1b[<0;{d};3m",
        .{ gutter + 1, gutter + 6, gutter + 6 },
    );
    var drag_items = try ui.input.decode(allocator, drag);
    defer drag_items.deinit(allocator);
    for (drag_items.items) |*item| {
        switch (item.*) {
            .key, .focus => return error.TestUnexpectedResult,
            .mouse => |*mouse| try handleMouseEvent(view, hover, find, null, editor, mouse),
        }
    }
    const selection = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 3), selection.selectionStartLineNumber);
    try std.testing.expectEqual(@as(usize, 1), selection.selectionStartColumn);
    try std.testing.expectEqual(@as(usize, 6), selection.positionColumn);

    var wheel_items = try ui.input.decode(allocator, "\x1b[<65;1;1M");
    defer wheel_items.deinit(allocator);
    for (wheel_items.items) |*item| {
        switch (item.*) {
            .key, .focus => return error.TestUnexpectedResult,
            .mouse => |*mouse| try handleMouseEvent(view, hover, find, null, editor, mouse),
        }
    }
    try std.testing.expectEqual(@as(usize, 4), editor.topViewLine());
    try std.testing.expectEqual(@as(usize, 3), editor.modelCursorPosition().lineNumber);

    const value = try editor.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings(text, value.items);
}

test "app: smart select shortcuts expand and shrink the selection" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "fooBar", "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try editor.setSelections(&[_]Selection{Selection.init(1, 2, 1, 2)});

    var pasting = false;
    const expand = input.KeyEvent{
        .key = .right,
        .mods = .{ .shift = true, .alt = true },
    };
    try std.testing.expect(!dispatch(editor, expand, &pasting));
    try std.testing.expectEqualDeep(Selection.init(1, 1, 1, 4), editor.modelSelection());

    const shrink = input.KeyEvent{
        .key = .left,
        .mods = .{ .shift = true, .alt = true },
    };
    try std.testing.expect(!dispatch(editor, shrink, &pasting));
    try std.testing.expectEqualDeep(Selection.init(1, 2, 1, 2), editor.modelSelection());
}

test "app: in-place replace shortcut cycles the value" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "true", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var pasting = false;
    const next = input.KeyEvent{
        .key = .{ .char = '.' },
        .mods = .{ .alt = true },
    };
    try std.testing.expect(!dispatch(editor, next, &pasting));
    const value = try editor.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("false", value.items);
}

test "app: navigation keys resolve through the keybinding registry" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "abc", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setSelections(&[_]Selection{Selection.init(1, 3, 1, 3)});

    const left = input.KeyEvent{ .key = .left };
    try std.testing.expect(try editor.dispatchShortcut(left));
    try std.testing.expectEqualDeep(Selection.init(1, 2, 1, 2), editor.modelSelection());

    const shift_left = input.KeyEvent{ .key = .left, .mods = .{ .shift = true } };
    try std.testing.expect(try editor.dispatchShortcut(shift_left));
    try std.testing.expectEqualDeep(Selection.init(1, 2, 1, 1), editor.modelSelection());

    // Smart selection is registered now and resolves through the host.
    const alt_shift_left = input.KeyEvent{ .key = .left, .mods = .{ .alt = true, .shift = true } };
    try std.testing.expect(try editor.dispatchShortcut(alt_shift_left));

    // Unregistered combinations keep falling back to the legacy dispatch.
    const ctrl_alt_left = input.KeyEvent{ .key = .left, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expect(!(try editor.dispatchShortcut(ctrl_alt_left)));
}

test "app: editing keys resolve through the keybinding registry" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "abc", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.setSelections(&[_]Selection{Selection.init(1, 3, 1, 3)});
    try std.testing.expect(try editor.dispatchShortcut(.{ .key = .enter }));
    try std.testing.expectEqual(@as(usize, 2), editor.model.getLineCount());

    try std.testing.expect(try editor.dispatchShortcut(.{ .key = .backspace }));
    try std.testing.expectEqual(@as(usize, 1), editor.model.getLineCount());

    try std.testing.expect(try editor.dispatchShortcut(.{ .key = .tab }));
    const line = try editor.model.getLineContent(1);
    defer line.deinit();
    // The default language configuration inserts spaces up to the tab stop;
    // the caret sits after "ab" once the newline is removed.
    try std.testing.expectEqualStrings("ab  c", line.items);
}

test "app: std.log routes engine diagnostics to the log file" {
    const allocator = std.testing.allocator;
    const buffer_log = @import("../vs/platform/log/common/bufferLog.zig");
    var sink: buffer_log.BufferLogger = undefined;
    sink.init(allocator, .debug);
    defer sink.deinit();

    const previous = std_log_sink;
    defer std_log_sink = previous;
    std_log_sink = sink.interface();

    logStd(.warn, .osc_iterm2, "unimplemented OSC 1337: {s}", .{"RemoteHost"});

    try std.testing.expectEqual(@as(usize, 1), sink.buffer.items.len);
    try std.testing.expectEqual(log_module.LogLevel.warning, sink.buffer.items[0].level);
    try std.testing.expectEqualStrings("osc_iterm2: unimplemented OSC 1337: RemoteHost", sink.buffer.items[0].message);
}

test "app: Helix and Vim modal runtimes disable each other" {
    const allocator = std.testing.allocator;
    const io = time_compat.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "modal.txt", .data = "hello\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{}\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const relative_len = try tmp.dir.realPathFile(io, "modal.txt", &path_buffer);
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
    vim.setOnEnable(.{ .context = helix, .on_enable = disableHelixForVim });
    helix.setOnEnable(.{ .context = vim, .on_enable = disableVimForHelix });

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

test "app: shutdown writes the current editor groups before didShutdown" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "two.txt", .data = "two" });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const one = try std.fs.path.join(allocator, &.{ root, "one.txt" });
    defer allocator.free(one);
    const two = try std.fs.path.join(allocator, &.{ root, "two.txt" });
    defer allocator.free(two);
    const path = try std.fs.path.join(allocator, &.{ root, "session.json" });
    defer allocator.free(path);
    const workbench_window = try TestWindow.init(allocator, io, &.{one}, 60, 20);
    const workbench = workbench_window.workbench;
    defer workbench_window.deinit();
    var serializers = EditorFactoryRegistry.init(allocator);
    defer serializers.deinit();
    var file = workbench.createFileSerializer();
    try serializers.registerEditorSerializer(FileEditorInput.TYPE_ID, file.interface());
    var writer = SessionOnShutdown{ .workbench = workbench, .registry = &serializers, .path = path, .log = null };
    _ = try workbench.on_will_shutdown.listen(&writer, SessionOnShutdown.save);
    const DidShutdown = struct {
        writer: *SessionOnShutdown,
        will_calls: u8 = 0,
        calls: u8 = 0,
        fn will(event: WillShutdownEvent, self: *@This()) !void {
            try std.testing.expectEqual(.quit, event.reason);
            self.will_calls += 1;
        }
        fn check(_: void, self: *@This()) !void {
            try std.testing.expectEqual(@as(u8, 1), self.will_calls);
            var restored = (try session.loadPart(self.writer.workbench.allocator, self.writer.workbench.io, self.writer.path)).?;
            defer restored.deinit(self.writer.workbench.allocator);
            try std.testing.expectEqual(@as(usize, 2), restored.groups[0].editors.len);
            self.calls += 1;
        }
    };
    var did = DidShutdown{ .writer = &writer };
    _ = try workbench.on_will_shutdown.listen(&did, DidShutdown.will);
    _ = try workbench.on_did_shutdown.listen(&did, DidShutdown.check);
    try workbench.openPath(two);
    try std.testing.expect((try session.loadPart(allocator, io, path)) == null);
    try workbench.lifecycle.shutdown(.quit);
    try workbench.lifecycle.shutdown(.quit);
    try std.testing.expectEqual(@as(u8, 1), did.calls);
}
