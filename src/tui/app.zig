const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const tui = @import("./tui.zig");
const cellBorders = @import("./cellBorders.zig");
const ui = @import("ui");
const input = ui.input;
const Editor = @import("./editor.zig").Editor;
const View = @import("./view.zig").View;
const Preview = @import("./preview.zig").Preview;
const Workbench = @import("./workbench.zig").Workbench;
const extensions = @import("./extensions.zig");
const session = @import("./session.zig");
const SyntaxTheme = @import("./syntaxTheme.zig").SyntaxTheme;
const FileEditorSerializer = @import("./editorInput.zig").FileEditorSerializer;
const FileEditorInput = @import("./editorInput.zig").FileEditorInput;
const EditorFactoryRegistry = @import("../vs/workbench/common/editor/editorFactory.zig").EditorFactoryRegistry;
const FindController = @import("../vs/editor/contrib/find/browser/findController.zig").FindController;
const word_character_classifier = @import("../vs/editor/common/core/wordCharacterClassifier.zig");
const editorBrowser = @import("../vs/editor/browser/editorBrowser.zig");
const Position = @import("../vs/editor/common/core/position.zig").Position;
const Range = @import("../vs/editor/common/core/range.zig").Range;
const Selection = @import("../vs/editor/common/core/selection.zig").Selection;
const time_compat = @import("../vs/base/common/timeCompat.zig");
const logger = @import("./logger.zig");
const log_module = @import("../vs/platform/log/common/log.zig");
const languages = @import("../vs/editor/common/languages.zig");
const hoverTypes = @import("../vs/editor/contrib/hover/browser/hoverTypes.zig");
const ContentHoverController = @import("../vs/editor/contrib/hover/browser/contentHoverController.zig").ContentHoverController;
const MarkdownHoverParticipant = @import("../vs/editor/contrib/hover/browser/markdownHoverParticipant.zig").MarkdownHoverParticipant;
const WordHighlighterContribution = @import("../vs/editor/contrib/wordHighlighter/browser/wordHighlighter.zig").WordHighlighterContribution;
const SuggestController = @import("../vs/editor/contrib/suggest/browser/suggestController.zig").SuggestController;
const WordBasedCompletionProvider = @import("../vs/editor/contrib/suggest/browser/wordBasedSuggestions.zig").WordBasedCompletionProvider;
const TuiHoverProvider = @import("./hoverProvider.zig").TuiHoverProvider;
const ArrayList = std.array_list.Managed;

/// Mirrors the previous `std.debug.print` error reporting, now also written to
/// the main log file.
fn report(log_service: ?log_module.ILogger, comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
    const logger_value = log_service orelse return;
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;
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
    extension_path: ?[]const u8 = null,
};

/// Parses `--preview`, `--session <file>` and the remaining paths.
/// `--preview` is only valid with exactly one path; `--session` restores the
/// saved group when the file exists and otherwise opens the given paths.
fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args, paths: *ArrayList([]const u8)) !Args {
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next(); // executable name

    var parsed: Args = .{};
    errdefer if (parsed.session) |session_path| allocator.free(session_path);
    errdefer if (parsed.extension_path) |path| allocator.free(path);
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--preview")) {
            parsed.preview = true;
        } else if (std.mem.eql(u8, arg, "--session")) {
            const value = it.next() orelse return error.MissingSessionPath;
            if (parsed.session) |old| allocator.free(old);
            parsed.session = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--extension-path")) {
            const value = it.next() orelse return error.MissingExtensionPath;
            if (parsed.extension_path) |old| allocator.free(old);
            parsed.extension_path = try allocator.dupe(u8, value);
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

/// User settings live outside the workspace. `VSCODE_TEXTBUFFER_USER_SETTINGS`
/// overrides the XDG/HOME default so tests and alternate profiles can point at
/// a specific file; a missing file simply produces no user scope.
/// Explicit `--extension-path`, the env override, then the extracted test
/// fixture. A user install is expected to pass the flag or the env var until
/// the manifest scanner lands.
fn defaultExtensionPath(allocator: std.mem.Allocator) ?[]u8 {
    if (std.c.getenv("VSCODE_TEXTBUFFER_EXTENSION_PATH")) |value| {
        return allocator.dupe(u8, std.mem.span(value)) catch null;
    }
    const fixture = ".cache-ext/vim/extension";
    std.Io.Dir.cwd().access(time_compat.io, fixture, .{}) catch return null;
    return allocator.dupe(u8, fixture) catch null;
}

fn defaultExtensionDataPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("VSCODE_TEXTBUFFER_EXTENSION_DATA")) |path| return allocator.dupe(u8, path);
    if (environ.get("XDG_STATE_HOME")) |state| return std.fs.path.join(allocator, &.{ state, "vscode-textbuffer", "extensions" });
    if (environ.get("HOME")) |home| return std.fs.path.join(allocator, &.{ home, ".local", "state", "vscode-textbuffer", "extensions" });
    return allocator.dupe(u8, ".cache-ext/data");
}

fn defaultUserSettingsPath(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !?[]u8 {
    if (environ.get("VSCODE_TEXTBUFFER_USER_SETTINGS")) |path| {
        return try allocator.dupe(u8, path);
    }
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        return try std.fs.path.join(allocator, &.{ xdg, "vscode-textbuffer", "settings.json" });
    }
    if (environ.get("HOME")) |home| {
        return try std.fs.path.join(allocator, &.{ home, ".config", "vscode-textbuffer", "settings.json" });
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var file_logger: ?*logger.FileLogger = null;
    const log_path = logger.defaultLogPath(allocator, init.environ_map) catch null;
    defer if (log_path) |path| allocator.free(path);
    if (log_path) |path| {
        file_logger = logger.FileLogger.create(allocator, io, path) catch |err| blk: {
            std.debug.print("log file unavailable: {s}\n", .{@errorName(err)});
            break :blk null;
        };
    }
    defer if (file_logger) |value| value.destroy();
    const log_service: ?log_module.ILogger = if (file_logger) |value| value.logger() else null;
    defer infoLog(log_service, "exit", .{});

    var syntax_theme: SyntaxTheme = undefined;
    syntax_theme.initFromThemeService(allocator) catch |err| {
        infoLog(log_service, "theme service unavailable: {s}; using the bundled loader", .{@errorName(err)});
        try syntax_theme.init(allocator);
    };
    defer syntax_theme.deinit();
    // The whole-word search classifier cache is process-lifetime by design;
    // release it before the safe allocator checks for leaks on exit.
    defer word_character_classifier.freeWordClassifierCache();

    var paths = ArrayList([]const u8).init(allocator);
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit();
    }

    const args = parseArgs(allocator, init.minimal.args, &paths) catch {
        std.debug.print(
            "usage: zig <folder> [<file>...]\n       zig <file>...\n       zig --session <file> [<folder>] [<file>...]\n       zig --preview <file>\n       zig --extension-path <dir> [<file>...]\n",
            .{},
        );
        return;
    };
    defer if (args.session) |session_path| allocator.free(session_path);
    defer if (args.extension_path) |path| allocator.free(path);
    infoLog(log_service, "starting: preview={} session={s} paths={d}", .{
        args.preview,
        args.session orelse "-",
        paths.items.len,
    });

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

    try tui.disableLineWrap(out);
    defer tui.enableLineWrap(out) catch {};

    try tui.enableMouseCapture(out);
    defer tui.disableMouseCapture(out) catch {};

    try tui.installSigWinch();

    var size = try tui.getTerminalSize();

    if (args.preview) {
        var editor = try Editor.create(allocator, io, paths.items[0], size.width, size.height);
        defer {
            editor.deinit();
            allocator.destroy(editor);
        }
        try runPreview(allocator, io, out, editor, size);
        return;
    }

    // Probe once, inside the alternate screen, before the first frame: the
    // answer decides whether borders reserve cells or paint on cell edges.
    const border_probe = try cellBorders.probe(allocator, io, out);
    defer border_probe.deinit(allocator);

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
        std.debug.print("no files or folders to open\n", .{});
        return;
    }

    var file_serializer: ?FileEditorSerializer = null;
    var registry: ?EditorFactoryRegistry = null;
    if (args.session != null) {
        // The workbench status bar takes one row and each group's tab strip
        // takes one; restored editors are opened as workbench panes, so their
        // content height is the remaining rows.
        const restored_editor_height = @max(size.height -| 2, 1);
        file_serializer = FileEditorSerializer.init(allocator, io, size.width, restored_editor_height);
        registry = EditorFactoryRegistry.init(allocator);
        try registry.?.registerEditorSerializer(FileEditorInput.TYPE_ID, file_serializer.?.interface());
    }
    defer if (registry) |*value| value.deinit();

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

            const created = Workbench.initFromSerializedPart(
                allocator,
                io,
                data,
                &registry.?,
                size.width,
                size.height,
            ) catch |err| blk: {
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
        workbench = try Workbench.init(allocator, io, files.items, size.width, size.height);
    }
    defer workbench.deinit();
    workbench.setCellBorders(border_probe.supported);

    const user_settings_path = try defaultUserSettingsPath(allocator, init.environ_map);
    defer if (user_settings_path) |path| allocator.free(path);
    try workbench.setUserSettingsPath(user_settings_path);

    if (args.session) |session_path| {
        defer {
            if (workbench.tabCount() > 0) {
                if (workbench.serializePart(allocator, &registry.?)) |data| {
                    var owned = data;
                    defer owned.deinit(allocator);
                    session.savePart(allocator, io, session_path, &data) catch |err| {
                        report(log_service, "session save failed: {s}", .{@errorName(err)});
                    };
                } else |err| {
                    report(log_service, "session serialize failed: {s}", .{@errorName(err)});
                }
            }
        }
    }

    if (folders.items.len > 0) {
        try workbench.setWorkspaceFolders(folders.items);
    }
    try workbench.initSidebarFromWorkspace();
    if (workbench.activeTab()) |active| {
        try active.ensureControllers();
    } else {
        workbench.focusSidebar();
    }

    var extension_host: ?*extensions.Extensions = null;
    defer if (extension_host) |ext| ext.deinit();
    const extension_path = if (args.extension_path) |path| path else defaultExtensionPath(allocator);
    if (extension_path) |path| {
        defer if (args.extension_path == null) allocator.free(path);
        const extension_data = try defaultExtensionDataPath(allocator, init.environ_map);
        defer allocator.free(extension_data);
        std.Io.Dir.cwd().createDirPath(io, extension_data) catch {};
        extension_host = extensions.Extensions.init(allocator, io, workbench, path, extension_data) catch |err| blk: {
            report(log_service, "extension host disabled: {s}", .{@errorName(err)});
            break :blk null;
        };
    }

    var input_buffer = try ArrayList(u8).initCapacity(allocator, 4096);
    defer input_buffer.deinit();
    if (border_probe.leftover) |leftover| try input_buffer.appendSlice(leftover);

    try tui.hideCursor(out);
    defer tui.showCursor(out) catch {};

    infoLog(log_service, "workbench ready: {d} tab(s)", .{workbench.tabCount()});
    workbench.refreshStatus();
    if (workbench.activeTab()) |active| try active.view.refresh();
    try workbench.render(out);
    try workbench.syncCursor(out);
    try out.flush();

    var needs_render = false;
    // A read can end in the middle of an escape sequence. Keep those bytes
    // and wait for the rest instead of decoding the tail as typed text.
    var awaiting_input_continuation = false;
    while (true) {
        const now_ms = time_compat.milliTimestamp();
        if (workbench.pollFileWatcher(now_ms)) needs_render = true;
        if (workbench.pollBreadcrumbs()) needs_render = true;
        if (try workbench.pollQuickAccess(now_ms)) needs_render = true;
        if (workbench.pollSearch(now_ms)) needs_render = true;
        if (extension_host) |ext| {
            if (ext.pump()) needs_render = true;
        }
        var timeout: i32 = 250;
        if (workbench.activeTab()) |active| {
            try active.ensureControllers();
            const controllers = active.controllers.?;

            if (active.editor.inPlaceReplaceTick(now_ms)) needs_render = true;
            if (controllers.hover.onTick(now_ms)) needs_render = true;
            if (controllers.word_highlighter.onTick(now_ms)) needs_render = true;
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
            if (needs_render) timeout = 0;
        }
        if (workbench.quickAccessWantsTick()) timeout = 0;
        if (workbench.searchWantsTick()) timeout = 0;
        if (workbench.fileWatcherTimeout(now_ms)) |watcher_timeout| {
            timeout = @min(timeout, @as(i32, @intCast(@min(watcher_timeout, 250))));
        }

        const polled = if (builtin.os.tag == .windows)
            try tui.pollInputWithHandle(workbench.fileWatcherHandle(), timeout)
        else
            try tui.pollInputWithFd(workbench.fileWatcherFd(), timeout);
        if (polled.extra) {
            if (workbench.pollFileWatcher(time_compat.milliTimestamp())) needs_render = true;
        }
        const ready = polled.input or
            (input_buffer.items.len != 0 and !awaiting_input_continuation);
        var resized = false;
        if (try tui.resizedSize()) |new_size| {
            size = new_size;
            try workbench.resize(size.width, size.height);
            try tui.clearScreen(out);
            resized = true;
        }

        if (!ready) {
            if (resized or needs_render) {
                if (workbench.activeTab()) |current| {
                    current.onEditorChanged(now_ms);
                    workbench.onSearchEditorChanged();
                    try current.view.refresh();
                }
                workbench.refreshStatus();
                try workbench.render(out);
                try workbench.syncCursor(out);
                try out.flush();
                needs_render = false;
            }
            continue;
        }

        // Leftover bytes from the capability probe are processed before a new
        // read; both the border reply and DA1 are ignored by the decoder.
        if (input_buffer.items.len == 0 or polled.input) {
            _ = try tui.readFd(io, 0, &input_buffer);
            awaiting_input_continuation = false;
        }

        const decoded = try input.decodeWithRemainder(allocator, input_buffer.items);
        var events = decoded.items;
        defer events.deinit(allocator);
        const consumed = decoded.consumed;

        for (events.items) |*item| {
            switch (item.*) {
                .key => |*event| {
                    if (isCtrlQ(event.*)) {
                        if (workbench.requestQuit()) return;
                        continue;
                    }
                    workbench.clearQuitArmed();
                    workbench.clearStatusHover();

                    if (try workbench.handleGlobalKey(event)) continue;
                    if (try workbench.handleQuickAccessKey(event)) continue;
                    if (try workbench.handleSidebarKey(event)) continue;
                    if (try workbench.handleStatusbarKey(event)) continue;

                    switch (try workbench.handleTabKey(event)) {
                        .quit => return,
                        .handled => continue,
                        .unhandled => {},
                    }
                    if (try workbench.handleBreadcrumbsKey(event)) continue;

                    if (extension_host) |ext| {
                        if (ext.handleKey(event)) {
                            _ = ext.pump();
                            needs_render = true;
                            continue;
                        }
                    }

                    const current = workbench.activeTab() orelse continue;
                    try current.ensureControllers();
                    current.editor.clearCloseTabArmed();

                    const tab_controllers = current.controllers.?;
                    if (try handleKeyEvent(
                        current.view,
                        tab_controllers.hover,
                        tab_controllers.word_highlighter,
                        tab_controllers.find,
                        tab_controllers.suggest,
                        current.editor,
                        event,
                        &workbench.is_pasting,
                        now_ms,
                    )) return;
                },
                .mouse => |*event| {
                    if (workbench.handleTabDragMouse(event)) continue;
                    if (workbench.handleQuickAccessMouse(event)) continue;
                    if (workbench.handleStatusbarMouse(event)) continue;
                    if (workbench.handleSashMouse(event)) continue;
                    if (workbench.handleSidebarMouse(event)) continue;
                    if (workbench.handleTabMouse(event)) continue;
                    workbench.clearQuitArmed();

                    var adjusted = workbench.editorMouseEvent(event.*) orelse continue;
                    const current = workbench.activeTab() orelse continue;
                    if (event.kind == .down) {
                        workbench.focusEditor();
                        current.editor.clearCloseTabArmed();
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
                        &adjusted,
                    ) catch |err| {
                        current.editor.setMessage("mouse failed: {s}", .{@errorName(err)});
                    };
                },
            }
        }
        if (consumed < input_buffer.items.len) {
            const remainder = input_buffer.items.len - consumed;
            std.mem.copyForwards(u8, input_buffer.items[0..remainder], input_buffer.items[consumed..]);
            input_buffer.shrinkRetainingCapacity(remainder);
            awaiting_input_continuation = true;
        } else {
            input_buffer.clearRetainingCapacity();
            awaiting_input_continuation = false;
        }

        if (workbench.activeTab()) |current| {
            current.onEditorChanged(time_compat.milliTimestamp());
            workbench.onSearchEditorChanged();
            try current.view.refresh();
        }
        workbench.refreshStatus();
        try tui.hideCursor(out);
        try workbench.render(out);
        try workbench.syncCursor(out);
        try out.flush();
        needs_render = false;
    }
}

/// Handles one decoded event. A focused widget owns the keyboard; Ctrl-Q stays
/// global so the quit prompt works from inside a widget, and Ctrl-F/Ctrl-R open
/// the find bar from either side (Ctrl-H is Backspace on terminals). Returns
/// true when the app should quit.
fn handleKeyEvent(
    view: *View,
    hover: *ContentHoverController,
    word_highlighter: *WordHighlighterContribution,
    find: *FindController,
    suggest: ?*SuggestController,
    editor: *Editor,
    event: *input.KeyEvent,
    is_pasting: *bool,
    now_ms: i64,
) !bool {
    if (isCtrlQ(event.*)) {
        const quit = dispatch(editor, event.*, is_pasting);
        find.onEditorChanged();
        return quit;
    }
    if (suggest) |controller| {
        if (try controller.handleKey(event, now_ms)) return false;
    }
    if (hover.onKeyDown(event)) return false;
    if (word_highlighter.handleKey(event)) {
        find.onEditorChanged();
        return false;
    }
    if (view.dispatchKey(event)) return false;
    if (suggest) |controller| {
        switch (event.key) {
            .char, .text, .enter, .tab, .backspace, .delete => controller.beforeTyping(),
            else => {},
        }
    }
    if (dispatch(editor, event.*, is_pasting)) return true;
    if (suggest) |controller| {
        if (printableChar(event.*)) |ch| {
            _ = try controller.onTypedCharacter(ch, now_ms);
        }
        _ = try controller.onEditorChanged();
    }
    find.onEditorChanged();
    return false;
}

fn printableChar(event: input.KeyEvent) ?u8 {
    return switch (event.key) {
        .char => |ch| if (ch >= 0x20 and ch <= 0x7e and !event.mods.ctrl and !event.mods.alt) @intCast(ch) else null,
        .text => |text| if (text.len == 1 and text[0] >= 0x20 and text[0] <= 0x7e) text[0] else null,
        else => null,
    };
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
        editor.clearQuitArmed();
        editor.clearMessage();
    }

    const target = try view.mouseTargetAt(event.x, event.y);
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

fn runPreview(allocator: std.mem.Allocator, io: Io, out: *Io.Writer, editor: *Editor, initial_size: tui.Size) !void {
    var size = initial_size;
    try tui.hideCursor(out);
    defer tui.showCursor(out) catch {};

    const preview = try Preview.init(allocator, editor);
    defer preview.deinit();

    try preview.render(out);
    try out.flush();

    var input_buffer = try ArrayList(u8).initCapacity(allocator, 256);
    defer input_buffer.deinit();

    while (true) {
        const ready = try tui.pollInput(250);

        if (try tui.resizedSize()) |new_size| {
            size = new_size;
            editor.setViewport(size.width, size.height);
            try preview.resize();
            try tui.clearScreen(out);
            try preview.render(out);
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
                .key => |*event| {
                    if (try preview.handleKey(event.*)) redraw = true;
                },
                .mouse => |*event| {
                    if (try preview.handleMouse(event)) redraw = true;
                },
            }
            if (preview.shouldQuit()) return;
        }
        if (consumed < input_buffer.items.len) {
            const remainder = input_buffer.items.len - consumed;
            std.mem.copyForwards(u8, input_buffer.items[0..remainder], input_buffer.items[consumed..]);
            input_buffer.shrinkRetainingCapacity(remainder);
        } else {
            input_buffer.clearRetainingCapacity();
        }
        if (redraw) {
            try preview.render(out);
            try out.flush();
        }
    }
}

fn isCtrlQ(event: input.KeyEvent) bool {
    return isCtrlChar(event, 'q');
}

fn isCtrlChar(event: input.KeyEvent, wanted: u21) bool {
    if (!event.mods.ctrl or event.mods.alt or event.mods.shift) return false;
    return switch (event.key) {
        .char => |ch| ch == wanted,
        else => false,
    };
}

fn setViewDecorations(context: ?*anyopaque, decorations: []const editorBrowser.Decoration) void {
    const view: *View = @ptrCast(@alignCast(context orelse return));
    view.setDecorations(decorations) catch {};
}

fn dispatch(editor: *Editor, event: input.KeyEvent, is_pasting: *bool) bool {
    if (!isCtrlQ(event)) {
        editor.clearQuitArmed();
        editor.clearMessage();
    }

    if (is_pasting.*) {
        switch (event.key) {
            .paste_end => {
                is_pasting.* = false;
                return false;
            },
            .text => |text| {
                editor.insertText(text) catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)});
                return false;
            },
            else => return false,
        }
    }

    if (std.meta.activeTag(event.key) == .char and event.mods.ctrl and !event.mods.alt and event.key.char == 'q') {
        return editor.requestQuit();
    }
    if (editor.dispatchShortcut(event) catch |err| blk: {
        editor.setMessage("shortcut failed: {s}", .{@errorName(err)});
        break :blk false;
    }) {
        return false;
    }

    switch (event.key) {
        .paste_start => {
            is_pasting.* = true;
            return false;
        },
        .paste_end => return false,
        .text => |text| {
            var offset: usize = 0;
            while (offset < text.len) {
                const length = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
                const end = @min(offset + length, text.len);
                editor.typeCharacter(text[offset..end]) catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)});
                offset = end;
            }
            return false;
        },
        .char => |ch| {
            var buffer: [4]u8 = undefined;
            const encoded = std.unicode.utf8Encode(ch, &buffer) catch return false;
            editor.typeCharacter(buffer[0..encoded]) catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)});
            return false;
        },
        .enter => editor.newline() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .tab => editor.insertTab() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .backtab => editor.outdent() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .backspace => editor.deleteLeft() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .delete => editor.deleteRight() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)}),
        .escape => {
            if (editor.cursorCount() > 1) {
                editor.removeSecondaryCursors() catch |err| editor.setMessage("remove cursors failed: {s}", .{@errorName(err)});
            } else {
                editor.cancelSelection() catch |err| editor.setMessage("edit failed: {s}", .{@errorName(err)});
            }
        },
        .left => {
            if (event.mods.alt and event.mods.shift) {
                editor.growSelection(false) catch |err| editor.setMessage("shrink selection failed: {s}", .{@errorName(err)});
            } else if (event.mods.ctrl) {
                editor.moveWordLeft(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            } else {
                editor.moveLeft(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            }
        },
        .right => {
            if (event.mods.alt and event.mods.shift) {
                editor.growSelection(true) catch |err| editor.setMessage("expand selection failed: {s}", .{@errorName(err)});
            } else if (event.mods.ctrl) {
                editor.moveWordRight(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            } else {
                editor.moveRight(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            }
        },
        .up => {
            if (event.mods.ctrl and event.mods.alt) {
                editor.addCursorAbove() catch |err| editor.setMessage("add cursor failed: {s}", .{@errorName(err)});
            } else if (event.mods.alt) {
                if (event.mods.shift) {
                    editor.copyLines(false) catch |err| editor.setMessage("copy lines failed: {s}", .{@errorName(err)});
                } else {
                    editor.moveLines(false) catch |err| editor.setMessage("move lines failed: {s}", .{@errorName(err)});
                }
            } else {
                editor.moveUp(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            }
        },
        .down => {
            if (event.mods.ctrl and event.mods.alt) {
                editor.addCursorBelow() catch |err| editor.setMessage("add cursor failed: {s}", .{@errorName(err)});
            } else if (event.mods.alt) {
                if (event.mods.shift) {
                    editor.copyLines(true) catch |err| editor.setMessage("copy lines failed: {s}", .{@errorName(err)});
                } else {
                    editor.moveLines(true) catch |err| editor.setMessage("move lines failed: {s}", .{@errorName(err)});
                }
            } else {
                editor.moveDown(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            }
        },
        .home => {
            if (event.mods.ctrl) {
                editor.moveDocStart(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            } else {
                editor.moveLineStart(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            }
        },
        .end => {
            if (event.mods.ctrl) {
                editor.moveDocEnd(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            } else {
                editor.moveLineEnd(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)});
            }
        },
        .page_up => editor.movePageUp(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)}),
        .page_down => editor.movePageDown(event.mods.shift) catch |err| editor.setMessage("move failed: {s}", .{@errorName(err)}),
        .insert => {},
    }
    return false;
}

test "app: q inserts text and Ctrl-Q is the quit key" {
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

    const ctrl_q = input.KeyEvent{ .key = .{ .char = 'q' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(!dispatch(editor, ctrl_q, &pasting));
    try std.testing.expect(editor.quit_armed);
    try std.testing.expect(dispatch(editor, ctrl_q, &pasting));
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
        try std.testing.expect(!try handleKeyEvent(view, hover, word_highlighter, find, null, editor, event, &pasting, 0));
    }

    try std.testing.expect(find.isOpen());
    try std.testing.expectEqualStrings("", find.state.search_string);

    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const open_row = try view.surface.grid().rowText(allocator, 0);
    defer allocator.free(open_row);
    try std.testing.expect(std.mem.indexOf(u8, open_row, "Find") != null);
    try std.testing.expect(view.surface.document().active_element != null);

    // Escape is handled by the widget, not inserted into the document.
    var close_events = try ui.input.decodeKeys(allocator, "\x1b");
    defer close_events.deinit(allocator);
    for (close_events.items) |*event| {
        try std.testing.expect(!try handleKeyEvent(view, hover, word_highlighter, find, null, editor, event, &pasting, 0));
    }
    try std.testing.expect(!find.isOpen());

    try view.refresh();
    try view.render(&out.writer);
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
    try view.render(&out.writer);

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
    try view.render(&out.writer);

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
    // `dddd` wraps to the second view line, which starts at model column 16.
    try std.testing.expectEqual(@as(usize, 16), viewModelColumnAtViewLineStart(view, Position.init(1, 18)));
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
    try view.render(&out.writer);

    const box = view.content_entries.items[0];
    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(u32, '┌'), grid.cluster[grid.index(box.left, box.top)]);
    try std.testing.expectEqual(@as(u32, '┘'), grid.cluster[grid.index(box.left + box.width - 1, box.top + box.height - 1)]);

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
    try view.render(&out.writer);
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
    try view.render(&out.writer);

    const entry = view.content_entries.items[0];
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
    try std.testing.expect(view.surface.document().active_element != null);
    try std.testing.expect(hover.isFocused());

    var escape = ui.KeyEvent{ .key = .escape };
    try std.testing.expect(view.dispatchKey(&escape));
    try std.testing.expect(!hover.isVisible());
    try std.testing.expect(view.surface.document().active_element == null);
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
    try view.render(&out.writer);

    const box = view.content_entries.items[0];
    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(u32, '┌'), grid.cluster[grid.index(box.left, box.top)]);
    try std.testing.expectEqual(@as(u32, '┘'), grid.cluster[grid.index(box.left + box.width - 1, box.top + box.height - 1)]);

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
    try view.render(&out.writer);

    const widget = hover.widget().widget;
    try std.testing.expect(widget.content_rows > widget.visible_rows);
    try std.testing.expect(widget.show_scrollbar);

    const top_before = editor.topViewLine();
    const entry = view.content_entries.items[0];
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
            .key => return error.TestUnexpectedResult,
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
            .key => return error.TestUnexpectedResult,
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
            .key => return error.TestUnexpectedResult,
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
