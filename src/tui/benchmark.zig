//! Debug-build benchmarks for the file-open/edit hot paths.
//!
//! The timing tests are opt-in so `zig build test` stays deterministic; the
//! viewport-tokenization contract test runs in the normal suite as well.
//! The `bench-open` build step compiles the same suite with
//! `build_options.bench = true` and runs the `benchmark:` filter:
//!
//!     zig build bench-open
//!     zig build bench-open -Dbench-file=<path>
//!
//! The default file is `src/tui/app.zig`. Timings use the monotonic clock and
//! the page allocator so the numbers reflect the app more closely than the
//! testing allocator does. They are diagnostics, not assertions: only the
//! structural checks (viewport tokenization, unattached model) assert.

const terminal_workbench = @import("workbench.zig");
const renderFrame = terminal_workbench.renderFrame;
const std = @import("std");
const ui = @import("ui");
const build_options = @import("build_options");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const time_compat = @import("../vs/base/common/timeCompat.zig");
const Editor = @import("../vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Tab = @import("../vs/workbench/browser/parts/editor/editorPane.zig").Tab;
const FileEditorInput = @import("../vs/workbench/contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const Position = @import("../vs/editor/common/core/position.zig").Position;
const TextualDocumentHighlightProvider = @import("../vs/editor/contrib/wordHighlighter/browser/textualHighlightProvider.zig").TextualDocumentHighlightProvider;

const iterations: usize = 5;

fn enabled() bool {
    return build_options.bench;
}

fn benchFile() []const u8 {
    return build_options.bench_file;
}

fn nowUs(io: Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMicroseconds();
}

const Stage = struct {
    name: []const u8,
    us: i64,
};

fn printStages(iteration: usize, stages: []const Stage, extra: []const u8) void {
    std.debug.print("[bench] iteration {d}", .{iteration});
    for (stages) |stage| std.debug.print(" {s}={d}us", .{ stage.name, stage.us });
    if (extra.len > 0) std.debug.print(" {s}", .{extra});
    std.debug.print("\n", .{});
}

/// Runs one editor/view/tab open and returns the stage timings. The caller
/// owns the returned tab and must deinit it.
fn openOnce(allocator: Allocator, io: Io, path: []const u8, stages: *[6]Stage) !*Tab {
    var t0 = nowUs(io);
    const editor = try Editor.createWithOptions(allocator, io, path, 140, 44, .{ .reserve_scrollbar = true });
    errdefer {
        editor.deinit();
        allocator.destroy(editor);
    }
    stages[0] = .{ .name = "editor", .us = nowUs(io) - t0 };

    t0 = nowUs(io);
    const input = try FileEditorInput.init(allocator, editor);
    errdefer input.deinit();
    const tab = try Tab.initFromInput(@import("./editorView.zig").View.createHandle, allocator, input);
    stages[1] = .{ .name = "view", .us = nowUs(io) - t0 };

    t0 = nowUs(io);
    try tab.view.setStatusBarVisible(false);
    stages[2] = .{ .name = "status", .us = nowUs(io) - t0 };

    t0 = nowUs(io);
    try tab.ensureControllers();
    stages[3] = .{ .name = "controllers", .us = nowUs(io) - t0 };

    t0 = nowUs(io);
    try tab.view.refresh();
    stages[4] = .{ .name = "refresh", .us = nowUs(io) - t0 };

    t0 = nowUs(io);
    try tab.view.paint();
    stages[5] = .{ .name = "paint", .us = nowUs(io) - t0 };

    return tab;
}

test "benchmark: open file" {
    if (!enabled()) return error.SkipZigTest;
    const allocator = std.heap.page_allocator;
    const io = time_compat.io;
    const path = benchFile();
    std.Io.Dir.cwd().access(io, path, .{}) catch return error.SkipZigTest;

    var first_total_us: i64 = 0;
    var best_total_us: i64 = std.math.maxInt(i64);
    for (0..iterations) |iteration| {
        var stages: [6]Stage = undefined;
        const start = nowUs(io);
        const tab = try openOnce(allocator, io, path, &stages);
        const total_us = nowUs(io) - start;

        const last_visible = tab.editor.modelLineNumber(
            tab.editor.topViewLine() + tab.editor.textHeight() -| 1,
        );
        const accurate = tab.editor.model.tokenization().hasAccurateTokensForLine(last_visible);
        try std.testing.expect(accurate);
        var extra_buf: [192]u8 = undefined;
        const extra = std.fmt.bufPrint(
            &extra_buf,
            "total={d}us renders={d} wraps={d} last_visible={d} tokens_accurate_first_paint={}",
            .{
                total_us,
                @import("./editorView.zig").View.nativeView(tab.view).renderCount(),
                tab.editor.view_lines.rebuildAllCount(),
                last_visible,
                accurate,
            },
        ) catch "";
        printStages(iteration, &stages, extra);

        if (iteration == 0) first_total_us = total_us;
        best_total_us = @min(best_total_us, total_us);
        tab.deinit();
    }
    std.debug.print(
        "[bench] open file {s}: first={d}us best={d}us\n",
        .{ path, first_total_us, best_total_us },
    );
}

test "benchmark: edit frame" {
    if (!enabled()) return error.SkipZigTest;
    const allocator = std.heap.page_allocator;
    const io = time_compat.io;
    const path = benchFile();
    std.Io.Dir.cwd().access(io, path, .{}) catch return error.SkipZigTest;

    var stages: [6]Stage = undefined;
    const tab = try openOnce(allocator, io, path, &stages);
    defer tab.deinit();

    try tab.view.refresh();
    try tab.view.paint();
    const wraps_before = tab.editor.view_lines.rebuildAllCount();

    var best_us: i64 = std.math.maxInt(i64);
    var last_us: i64 = 0;
    var edit_total: i64 = 0;
    var refresh_total: i64 = 0;
    var paint_total: i64 = 0;
    for (0..10) |i| {
        const start = nowUs(io);
        try tab.editor.insertText("x");
        const after_edit = nowUs(io);
        try tab.view.refresh();
        const after_refresh = nowUs(io);
        try tab.view.paint();
        const after_paint = nowUs(io);
        last_us = after_paint - start;
        edit_total += after_edit - start;
        refresh_total += after_refresh - after_edit;
        paint_total += after_paint - after_refresh;
        best_us = @min(best_us, last_us);
        std.debug.print("[bench] edit {d}: {d}us edit={d} refresh={d} paint={d}\n", .{
            i,
            last_us,
            after_edit - start,
            after_refresh - after_edit,
            after_paint - after_refresh,
        });
    }
    const edit_perf = @import("./editorView.zig").View.nativeView(tab.view).perfCounters();
    std.debug.print(
        "[bench] edit frame {s}: best={d}us last={d}us avg_edit={d}us avg_refresh={d}us avg_paint={d}us wraps_delta={d} chrome_renders={d} chrome_ops=+{d}/~{d}/>{d}/-{d} syncs={d}\n",
        .{
            path,
            best_us,
            last_us,
            @divTrunc(edit_total, 10),
            @divTrunc(refresh_total, 10),
            @divTrunc(paint_total, 10),
            tab.editor.view_lines.rebuildAllCount() - wraps_before,
            edit_perf.chrome_rebuilds,
            edit_perf.chrome_subtrees_added,
            edit_perf.chrome_subtrees_rebuilt,
            edit_perf.chrome_subtrees_translated,
            edit_perf.chrome_subtrees_removed,
            edit_perf.incremental_syncs,
        },
    );
}

test "benchmark: scroll frame" {
    if (!enabled()) return error.SkipZigTest;
    const allocator = std.heap.page_allocator;
    const io = time_compat.io;
    const path = benchFile();
    std.Io.Dir.cwd().access(io, path, .{}) catch return error.SkipZigTest;

    var stages: [6]Stage = undefined;
    const tab = try openOnce(allocator, io, path, &stages);
    defer tab.deinit();
    try tab.view.refresh();
    try tab.view.paint();

    const line_iterations: usize = 50;
    var line_best: i64 = std.math.maxInt(i64);
    var line_refresh: i64 = 0;
    var line_paint: i64 = 0;
    for (0..line_iterations) |_| {
        const start = nowUs(io);
        _ = tab.editor.scrollViewLines(1);
        const after_scroll = nowUs(io);
        try tab.view.refresh();
        const after_refresh = nowUs(io);
        try tab.view.paint();
        const after_paint = nowUs(io);
        line_best = @min(line_best, after_paint - start);
        line_refresh += after_refresh - after_scroll;
        line_paint += after_paint - after_refresh;
    }

    _ = tab.editor.setTopViewLine(1);
    const page_iterations: usize = 10;
    var page_best: i64 = std.math.maxInt(i64);
    for (0..page_iterations) |_| {
        const start = nowUs(io);
        _ = tab.editor.scrollViewLines(@intCast(tab.editor.textHeight()));
        try tab.view.refresh();
        try tab.view.paint();
        page_best = @min(page_best, nowUs(io) - start);
    }

    _ = tab.editor.setTopViewLine(1);
    const wheel_iterations: usize = 20;
    var wheel_best: i64 = std.math.maxInt(i64);
    for (0..wheel_iterations) |_| {
        const start = nowUs(io);
        _ = tab.editor.scrollViewLines(3);
        try tab.view.refresh();
        try tab.view.paint();
        wheel_best = @min(wheel_best, nowUs(io) - start);
    }

    const scroll_perf = @import("./editorView.zig").View.nativeView(tab.view).perfCounters();
    std.debug.print(
        "[bench] scroll frame {s}: line_best={d}us avg_refresh={d}us avg_paint={d}us page_best={d}us wheel_best={d}us renders={d} chrome_renders={d} chrome_ops=+{d}/~{d}/>{d}/-{d} syncs={d}\n",
        .{
            path,
            line_best,
            @divTrunc(line_refresh, @as(i64, @intCast(line_iterations))),
            @divTrunc(line_paint, @as(i64, @intCast(line_iterations))),
            page_best,
            wheel_best,
            @import("./editorView.zig").View.nativeView(tab.view).renderCount(),
            scroll_perf.chrome_rebuilds,
            scroll_perf.chrome_subtrees_added,
            scroll_perf.chrome_subtrees_rebuilt,
            scroll_perf.chrome_subtrees_translated,
            scroll_perf.chrome_subtrees_removed,
            scroll_perf.incremental_syncs,
        },
    );
}

test "benchmark: word highlight" {
    if (!enabled()) return error.SkipZigTest;
    const allocator = std.heap.page_allocator;
    const io = time_compat.io;
    const path = benchFile();
    std.Io.Dir.cwd().access(io, path, .{}) catch return error.SkipZigTest;

    var stages: [6]Stage = undefined;
    const tab = try openOnce(allocator, io, path, &stages);
    defer tab.deinit();

    const start = nowUs(io);
    const highlights = try TextualDocumentHighlightProvider.provideDocumentHighlights(
        allocator,
        tab.editor.model,
        Position.init(1, 2),
    );
    defer allocator.free(highlights);
    std.debug.print(
        "[bench] word highlight {s}: {d}us matches={d}\n",
        .{ path, nowUs(io) - start, highlights.len },
    );
}

test "Tokenization: visible range is synchronous, background is chunked" {
    const allocator = std.heap.page_allocator;
    const io = time_compat.io;

    var text: Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    for (0..300) |i| {
        try text.writer.print("const value_{d} = {d};\n", .{ i, i });
    }

    const editor = try Editor.createFromText(allocator, io, text.written(), "bench.zig", 120, 12);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    // Visible-line tokenization is forced synchronously, like upstream.
    editor.ensureTokensVisible();
    const last_visible = editor.modelLineNumber(editor.topViewLine() + editor.textHeight() -| 1);
    try std.testing.expect(editor.model.tokenization().hasAccurateTokensForLine(last_visible));
    if (last_visible + 2 <= editor.model.getLineCount()) {
        try std.testing.expect(!editor.model.tokenization().hasAccurateTokensForLine(last_visible + 2));
    }

    // Scrolling tokenizes the visible range from a guessed start state instead
    // of walking every line from the top. The visible line is colored (it has
    // real syntax tokens) even though the skipped history above it is still
    // flagged inaccurate until the background tokenizer reaches it.
    _ = editor.setTopViewLine(200);
    editor.ensureTokensVisible();
    const scrolled_last = editor.modelLineNumber(editor.topViewLine() + editor.textHeight() -| 1);
    {
        var scrolled_tokens = try editor.model.tokenization().getLineTokens(scrolled_last);
        defer scrolled_tokens.deinit();
        try std.testing.expect(scrolled_tokens.getCount() > 1);
    }
    if (scrolled_last + 10 <= editor.model.getLineCount()) {
        try std.testing.expect(!editor.model.tokenization().hasAccurateTokensForLine(scrolled_last + 10));
    }

    // The model is attached so the default background tokenizer can run; the
    // main loop advances it in ~1 ms chunks from idle ticks.
    try std.testing.expectEqual(@as(usize, 1), editor.model.getAttachedEditorCount());
    try std.testing.expect(editor.backgroundTokenizationPending());
    var polls: usize = 0;
    while (editor.pollBackgroundTokenization() and polls < 100_000) polls += 1;
    try std.testing.expect(!editor.backgroundTokenizationPending());
    try std.testing.expect(editor.model.tokenization().hasAccurateTokensForLine(editor.model.getLineCount()));

    std.debug.print(
        "[bench] tokenization scope: first_viewport={d} scrolled_viewport={d} attached={d} background_polls={d}\n",
        .{ last_visible, scrolled_last, editor.model.getAttachedEditorCount(), polls },
    );
}

test "benchmark: deferred maintenance" {
    if (!enabled()) return error.SkipZigTest;
    const allocator = std.heap.page_allocator;
    const io = time_compat.io;
    const path = benchFile();
    std.Io.Dir.cwd().access(io, path, .{}) catch return error.SkipZigTest;

    var stages: [6]Stage = undefined;
    const tab = try openOnce(allocator, io, path, &stages);
    defer tab.deinit();
    try tab.view.refresh();
    try tab.view.paint();

    var start = nowUs(io);
    var background_polls: usize = 0;
    while (tab.editor.pollBackgroundTokenization() and background_polls < 100_000) background_polls += 1;
    const background_us = nowUs(io) - start;

    start = nowUs(io);
    tab.editor.refreshFoldingIfDirty();
    const folding_us = nowUs(io) - start;

    start = nowUs(io);
    try tab.editor.model.bracketPairs().updateNow();
    const guides_us = nowUs(io) - start;

    std.debug.print(
        "[bench] deferred maintenance {s}: background={d}us(polls={d}) folding={d}us bracket_guides={d}us\n",
        .{ path, background_us, background_polls, folding_us, guides_us },
    );
}

test "benchmark: workbench scroll frame" {
    if (!enabled()) return error.SkipZigTest;
    const allocator = std.heap.page_allocator;
    const io = time_compat.io;
    const path = benchFile();
    std.Io.Dir.cwd().access(io, path, .{}) catch return error.SkipZigTest;

    var surface: @import("ui").Surface = undefined;
    try terminal_workbench.initWindowSurface(&surface, allocator, 140, 44);
    defer surface.deinit();
    const workbench = try @import("app.zig").startWorkbench(allocator, io, &surface, &.{path}, null);
    defer workbench.deinit();
    const tab = workbench.activeTab() orelse return error.SkipZigTest;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try tab.view.refresh();
    try renderFrame(workbench, &out.writer);
    out.clearRetainingCapacity();
    while (tab.editor.pollBackgroundTokenization()) {}

    const frames: usize = 20;
    var render_us_total: i64 = 0;
    var refresh_us_total: i64 = 0;
    var best: i64 = std.math.maxInt(i64);
    var scroll_us_total: i64 = 0;
    for (0..frames) |_| {
        const frame_start = nowUs(io);
        const scroll_start = nowUs(io);
        _ = tab.editor.scrollViewLines(3);
        scroll_us_total += nowUs(io) - scroll_start;
        const refresh_start = nowUs(io);
        try tab.view.refresh();
        refresh_us_total += nowUs(io) - refresh_start;

        const render_start = nowUs(io);
        try renderFrame(workbench, &out.writer);
        render_us_total += nowUs(io) - render_start;
        out.clearRetainingCapacity();

        best = @min(best, nowUs(io) - frame_start);
    }

    const workbench_perf = @import("./editorView.zig").View.nativeView(tab.view).perfCounters();
    std.debug.print(
        "[bench] workbench scroll {s}: best={d}us avg_scroll={d}us avg_refresh={d}us avg_render={d}us chrome_renders={d} chrome_ops=+{d}/~{d}/>{d}/-{d} syncs={d}\n",
        .{
            path,
            best,
            @divTrunc(scroll_us_total, @as(i64, @intCast(frames))),
            @divTrunc(refresh_us_total, @as(i64, @intCast(frames))),
            @divTrunc(render_us_total, @as(i64, @intCast(frames))),
            workbench_perf.chrome_rebuilds,
            workbench_perf.chrome_subtrees_added,
            workbench_perf.chrome_subtrees_rebuilt,
            workbench_perf.chrome_subtrees_translated,
            workbench_perf.chrome_subtrees_removed,
            workbench_perf.incremental_syncs,
        },
    );
}

test "benchmark: explorer sidebar scroll" {
    if (!enabled()) return error.SkipZigTest;
    const allocator = std.heap.page_allocator;
    const io = time_compat.io;
    var surface: @import("ui").Surface = undefined;
    try terminal_workbench.initWindowSurface(&surface, allocator, 140, 44);
    defer surface.deinit();
    const workbench = try @import("app.zig").startWorkbench(allocator, io, &surface, &.{}, null);
    defer workbench.deinit();
    try workbench.initSidebar(".");
    const sidebar = workbench.sidebar orelse return error.SkipZigTest;

    var load_guard: usize = 0;
    while (sidebar.hasPendingLoad() and load_guard < 5000) : (load_guard += 1) {
        _ = workbench.window_events.dispatch(time_compat.milliTimestamp());
        if (sidebar.hasPendingLoad()) std.Io.sleep(workbench.async_io, .fromMilliseconds(1), .awake) catch {};
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderFrame(workbench, &out.writer);
    out.clearRetainingCapacity();

    const rect = sidebar.last_rect;
    const x = ui.cell.snap(rect.x) + 2;
    const y = ui.cell.snap(rect.y) + sidebar.header_rows + 1;
    const frames: usize = 20;
    var total_us: i64 = 0;
    var best_us: i64 = std.math.maxInt(i64);
    for (0..frames) |_| {
        const start = nowUs(io);
        const wheel = ui.MouseEvent{ .kind = .wheel, .x = x, .y = y, .delta_y = 1 };
        _ = terminal_workbench.handleSidebarMouse(workbench, &wheel);
        try renderFrame(workbench, &out.writer);
        out.clearRetainingCapacity();
        const elapsed = nowUs(io) - start;
        total_us += elapsed;
        best_us = @min(best_us, elapsed);
    }
    std.debug.print(
        "[bench] explorer sidebar scroll rows={d} best={d}us avg={d}us\n",
        .{ sidebar.count(), best_us, @divTrunc(total_us, @as(i64, @intCast(frames))) },
    );
}

// Real Git resources, native request/reply, retained editor controls and the
// workbench ANSI frame. Timings are diagnostics rather than platform gates.
const BenchPattern = enum { identical, one, many, insert_all, delete_all };
const BenchCase = struct { path: []const u8, lines: usize, pattern: BenchPattern };
const BenchWindow = @import("../vs/workbench/test/browser/workbenchTestServices.zig").TestWindow(terminal_workbench.TerminalWorkbench, @import("./editorView.zig").View.createHandle);
const BenchSnapshotSource = @import("../vs/editor/browser/widget/diffEditor/diffProviderFactoryService.zig").SnapshotSource;

const BenchAllocation = struct {
    child: Allocator = std.heap.page_allocator,
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *BenchAllocation) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn grow(self: *BenchAllocation, len: usize) void {
        const previous = self.live.fetchAdd(len, .monotonic);
        _ = self.peak.fetchMax(previous + len, .monotonic);
    }
    fn account(self: *BenchAllocation, old: usize, new: usize) void {
        if (new > old) self.grow(new - old) else _ = self.live.fetchSub(old - new, .monotonic);
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *BenchAllocation = @ptrCast(@alignCast(ctx));
        const result = self.child.vtable.alloc(self.child.ptr, len, alignment, address);
        if (result != null) self.grow(len);
        return result;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
        const self: *BenchAllocation = @ptrCast(@alignCast(ctx));
        const result = self.child.vtable.resize(self.child.ptr, memory, alignment, len, address);
        if (result) self.account(memory.len, len);
        return result;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
        const self: *BenchAllocation = @ptrCast(@alignCast(ctx));
        const result = self.child.vtable.remap(self.child.ptr, memory, alignment, len, address);
        if (result != null) self.account(memory.len, len);
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *BenchAllocation = @ptrCast(@alignCast(ctx));
        _ = self.live.fetchSub(memory.len, .monotonic);
        self.child.vtable.free(self.child.ptr, memory, alignment, address);
    }
};

const BenchDiffTimes = struct {
    acquisition_us: std.atomic.Value(i64) = .init(0),
    original_bytes: std.atomic.Value(usize) = .init(0),
    modified_bytes: std.atomic.Value(usize) = .init(0),
    submit_us: i64 = 0,
    worker_us: i64 = 0,
    mount_us: i64 = 0,
    first_frame_us: i64 = 0,
    total_us: i64 = 0,
    cache_hit: bool = false,
};

const TimedBenchSource = struct {
    inner: BenchSnapshotSource,
    io: Io,
    timings: *BenchDiffTimes,

    fn wrap(inner: BenchSnapshotSource, io: Io, timings: *BenchDiffTimes) !BenchSnapshotSource {
        errdefer inner.destroy(inner.context);
        const self = try std.heap.page_allocator.create(TimedBenchSource);
        self.* = .{ .inner = inner, .io = io, .timings = timings };
        return .{ .context = self, .read = read, .destroy = destroy };
    }
    fn read(context: *anyopaque, a: Allocator) !BenchSnapshotSource.Texts {
        const self: *TimedBenchSource = @ptrCast(@alignCast(context));
        const start = nowUs(self.io);
        defer self.timings.acquisition_us.store(nowUs(self.io) - start, .release);
        const result = try self.inner.read(self.inner.context, a);
        self.timings.original_bytes.store(result.original.len, .release);
        self.timings.modified_bytes.store(result.modified.len, .release);
        return result;
    }
    fn destroy(context: *anyopaque) void {
        const self: *TimedBenchSource = @ptrCast(@alignCast(context));
        self.inner.destroy(self.inner.context);
        std.heap.page_allocator.destroy(self);
    }
};

fn benchGit(a: Allocator, io: Io, root: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.append(a, "git");
    try argv.appendSlice(a, args);
    const result = std.process.run(a, io, .{
        .argv = argv.items,
        .cwd = .{ .path = root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(30_000), .clock = .awake } },
    }) catch return error.SkipZigTest;
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    if (!result.term.success()) return error.BenchmarkGitFailed;
}

fn benchDiffText(a: Allocator, n: usize, pattern: BenchPattern, modified: bool) ![]u8 {
    if ((pattern == .insert_all and !modified) or (pattern == .delete_all and modified)) return a.dupe(u8, "");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    for (0..n) |i| {
        const changed = modified and switch (pattern) {
            .one => i >= n / 2 and i < n / 2 + 3,
            .many => i % 10 == 5,
            else => false,
        };
        try out.writer.print("{d} {s}", .{ i, if (changed) "new" else "old" });
        if (i + 1 < n) try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn benchNativeDiffOpen(wb: *terminal_workbench.TerminalWorkbench, io: Io, path: []const u8, refresh: bool, timings: *BenchDiffTimes, out: *std.Io.Writer.Allocating) !*Tab {
    const start = nowUs(io);
    const inner = try wb.git_model.snapshotSource(wb.worker_io, path, null, .head, .working, refresh);
    const source = try TimedBenchSource.wrap(inner, io, timings);
    try wb.editor_opening.requestOpenSnapshotDiff(wb.configuration_api, path, source, "HEAD", "Working Tree");
    timings.submit_us = nowUs(io) - start;
    const worker = wb.editor_opening.diff_worker orelse return error.BenchmarkExpectedWorker;
    worker.waitForReply();
    const ready = nowUs(io);
    timings.worker_us = ready - start - timings.submit_us;
    if (wb.editor_opening.pending_diff) |pending| timings.cache_hit = pending.request.cache_hit;
    while (wb.editor_opening.pending_diff != null) {
        _ = wb.window_events.dispatch(time_compat.milliTimestamp());
        if (wb.editor_opening.pending_diff != null) std.Io.sleep(wb.async_io, .fromMilliseconds(1), .awake) catch {};
    }
    timings.mount_us = nowUs(io) - ready;
    const tab = wb.activeTab() orelse return error.BenchmarkExpectedDiff;
    if (tab.diff == null) return error.BenchmarkExpectedDiff;
    const frame_start = nowUs(io);
    try renderFrame(wb, &out.writer);
    out.clearRetainingCapacity();
    timings.first_frame_us = nowUs(io) - frame_start;
    timings.total_us = nowUs(io) - start;
    return tab;
}

/// Cumulative process resident-set high-water mark. Linux reports KiB,
/// macOS reports bytes; other targets keep zero (unavailable).
fn benchPeakRssBytes() usize {
    const system = @import("builtin").os.tag;
    if (system == .macos or system == .linux) {
        const usage = std.posix.getrusage(std.posix.rusage.SELF);
        const bytes: usize = @intCast(@max(usage.maxrss, 0));
        return if (system == .linux) bytes * 1024 else bytes;
    }
    return 0;
}

fn benchPercentile(samples: []i64, p: usize) i64 {
    std.mem.sort(i64, samples, {}, std.sort.asc(i64));
    return samples[(samples.len - 1) * p / 100];
}

fn benchNativeDiffInteractions(wb: *terminal_workbench.TerminalWorkbench, tab: *Tab, io: Io, out: *std.Io.Writer.Allocating, requested_hunks: usize) !void {
    const widget = tab.diff.?.widget;
    const view_type = @import("./editorView.zig").View;
    const original_view = view_type.nativeView(widget.original_view);
    const modified_view = view_type.nativeView(widget.modified_view);
    const original_before = original_view.renderCount();
    const modified_before = modified_view.renderCount();
    const samples_count = 50;
    var scroll_samples: [samples_count]i64 = undefined;
    var gutter_samples: [samples_count]i64 = undefined;
    var move_samples: [samples_count]i64 = undefined;
    var key_samples: [samples_count]i64 = undefined;
    var mouse_frame_samples: [samples_count]i64 = undefined;
    var key_frame_samples: [samples_count]i64 = undefined;
    const Gutter = @import("../vs/editor/browser/widget/diffEditor/features/gutterFeature.zig").DiffEditorGutter;
    const state = widget.state() orelse return error.BenchmarkExpectedDiff;
    const gutter: Gutter = .{ .mappings = state.mappings, .original = widget.original_editor, .modified = widget.modified_editor };
    var visible_items: usize = 0;
    for (0..samples_count) |i| {
        const start = nowUs(io);
        _ = widget.modified_editor.scrollViewLines(3);
        try renderFrame(wb, &out.writer);
        out.clearRetainingCapacity();
        scroll_samples[i] = nowUs(io) - start;
        const gutter_start = nowUs(io);
        var items = gutter.render(widget.modified_editor.scrollTop(), 50);
        while (items.next()) |_| visible_items += 1;
        gutter_samples[i] = nowUs(io) - gutter_start;
    }
    for (0..samples_count) |i| {
        var mouse: ui.MouseEvent = .{ .kind = .move, .x = 20 + i % 10, .y = 5 + i % 30 };
        const start = nowUs(io);
        _ = try widget.dispatchMouse(&mouse);
        move_samples[i] = nowUs(io) - start;
        const paint_start = nowUs(io);
        try renderFrame(wb, &out.writer);
        out.clearRetainingCapacity();
        mouse_frame_samples[i] = nowUs(io) - paint_start;
    }
    for (0..samples_count) |i| {
        var key: ui.KeyEvent = .{ .key = .down };
        const start = nowUs(io);
        _ = widget.dispatchKey(&key);
        key_samples[i] = nowUs(io) - start;
        const paint_start = nowUs(io);
        try renderFrame(wb, &out.writer);
        out.clearRetainingCapacity();
        key_frame_samples[i] = nowUs(io) - paint_start;
    }
    const original_perf = original_view.perfCounters();
    const modified_perf = modified_view.perfCounters();
    std.debug.print(
        "[bench] diff-scroll requested_hunks={d} actual_hunks={d} rows={d} scroll_p50={d}us scroll_p95={d}us gutter_layout_p50={d}us gutter_layout_p95={d}us visible_items={d} mouse_p50={d}us mouse_p95={d}us mouse_frame_p50={d}us mouse_frame_p95={d}us key_p50={d}us key_p95={d}us key_frame_p50={d}us key_frame_p95={d}us renders={d}/{d} solves={d}/{d} syncs={d}/{d}\n",
        .{
            requested_hunks,                         state.mappings.len,                            widget.modified_editor.textHeight(),
            benchPercentile(&scroll_samples, 50),    benchPercentile(&scroll_samples, 95),          benchPercentile(&gutter_samples, 50),
            benchPercentile(&gutter_samples, 95),    visible_items,                                 benchPercentile(&move_samples, 50),
            benchPercentile(&move_samples, 95),      benchPercentile(&mouse_frame_samples, 50),     benchPercentile(&mouse_frame_samples, 95),
            benchPercentile(&key_samples, 50),       benchPercentile(&key_samples, 95),             benchPercentile(&key_frame_samples, 50),
            benchPercentile(&key_frame_samples, 95), original_view.renderCount() - original_before, modified_view.renderCount() - modified_before,
            original_perf.full_box_solves,           modified_perf.full_box_solves,                 original_perf.incremental_syncs,
            modified_perf.incremental_syncs,
        },
    );
}

test "benchmark: native Git diff editor open, scroll, input and refresh" {
    if (!enabled()) return error.SkipZigTest;
    const io = std.testing.io;
    const scratch = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(scratch);
    defer arena.deinit();
    const names = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    try benchGit(scratch, io, root, &.{"init"});
    try benchGit(scratch, io, root, &.{ "config", "core.autocrlf", "false" });
    try benchGit(scratch, io, root, &.{ "config", "user.name", "Diff Benchmark" });
    try benchGit(scratch, io, root, &.{ "config", "user.email", "benchmark@example.invalid" });
    var cases: [15]BenchCase = undefined;
    var next: usize = 0;
    for ([_]usize{ 1000, 10000, 100000 }) |n| {
        for (std.meta.tags(BenchPattern)) |pattern| {
            const name = try std.fmt.allocPrint(names, "diff-{d}-{s}.txt", .{ n, @tagName(pattern) });
            const path = try std.fs.path.join(names, &.{ root, name });
            const original = try benchDiffText(scratch, n, pattern, false);
            defer scratch.free(original);
            try tmp.dir.writeFile(io, .{ .sub_path = name, .data = original });
            cases[next] = .{ .path = path, .lines = n, .pattern = pattern };
            next += 1;
        }
    }
    try benchGit(scratch, io, root, &.{ "add", "." });
    try benchGit(scratch, io, root, &.{ "-c", "commit.gpgsign=false", "commit", "-m", "benchmark fixture" });
    for (cases) |item| {
        const modified = try benchDiffText(scratch, item.lines, item.pattern, true);
        defer scratch.free(modified);
        try tmp.dir.writeFile(io, .{ .sub_path = std.fs.path.basename(item.path), .data = modified });
    }

    var allocation: BenchAllocation = .{};
    const a = allocation.allocator();
    const window = try BenchWindow.init(a, io, &.{}, 160, 55);
    defer window.deinit();
    const wb = window.workbench;
    const settings = try std.fs.path.join(names, &.{ root, ".git", "bench-settings.json" });
    try wb.setUserSettingsPaths(&.{settings});
    try wb.initSidebar(root);
    while (wb.sidebar.?.hasPendingLoad()) {
        _ = wb.window_events.dispatch(time_compat.milliTimestamp());
        if (wb.sidebar.?.hasPendingLoad()) std.Io.sleep(wb.async_io, .fromMilliseconds(1), .awake) catch {};
    }
    try wb.initGit();
    try wb.setUserConfigurationValue("diffEditor.renderSideBySide", .{ .bool = true });
    try wb.setUserConfigurationValue("diffEditor.useInlineViewWhenSpaceIsLimited", .{ .bool = false });
    try wb.setUserConfigurationValue("diffEditor.hideUnchangedRegions.enabled", .{ .bool = false });
    try wb.setUserConfigurationValue("diffEditor.diffAlgorithm", .{ .string = "advanced" });
    try wb.setUserConfigurationValue("diffEditor.wordWrap", .{ .string = "off" });
    var out: std.Io.Writer.Allocating = .init(scratch);
    defer out.deinit();

    const baseline_tabs = wb.tabCount();
    for (cases) |item| {
        for ([_]i64{ 0, 100, 5000 }) |budget| {
            for ([_]bool{ false, true }) |moves| {
                try wb.setUserConfigurationValue("diffEditor.maxComputationTime", .{ .integer = budget });
                try wb.setUserConfigurationValue("diffEditor.experimental.showMoves", .{ .bool = moves });
                const baseline = allocation.live.load(.monotonic);
                allocation.peak.store(baseline, .monotonic);
                var times: BenchDiffTimes = .{};
                const tab = try benchNativeDiffOpen(wb, io, item.path, false, &times, &out);
                const widget = tab.diff.?.widget;
                const state = widget.state() orelse return error.BenchmarkExpectedDiff;
                try std.testing.expect(widget.sideBySide());
                const original_lines = widget.original_editor.model.getLineCount();
                const modified_lines = widget.modified_editor.model.getLineCount();
                try std.testing.expectEqual(if (item.pattern == .insert_all) @as(usize, 1) else item.lines, original_lines);
                try std.testing.expectEqual(if (item.pattern == .delete_all) @as(usize, 1) else item.lines, modified_lines);
                const peak = allocation.peak.load(.monotonic) -| baseline;
                const acq = times.acquisition_us.load(.acquire);
                std.debug.print(
                    "[bench] diff-open n={d} case={s} budget={d} moves={} acquisition={d}us compute_and_handoff={d}us submit={d}us mount={d}us first_frame={d}us total={d}us original_bytes={d} modified_bytes={d} model_lines={d}/{d} view_lines={d}/{d} hunks={d} moved={d} quitEarly={} decorations={d}/{d} zones={d}/{d} window_peak_delta={d}B process_peak_rss={d}B\n",
                    .{
                        item.lines,                          @tagName(item.pattern),                  budget,                                  moves,
                        acq,                                 @max(0, times.worker_us - acq),          times.submit_us,                         times.mount_us,
                        times.first_frame_us,                times.total_us,                          times.original_bytes.load(.acquire),     times.modified_bytes.load(.acquire),
                        original_lines,                      modified_lines,                          widget.original_editor.viewLineCount(),  widget.modified_editor.viewLineCount(),
                        state.mappings.len,                  state.moved_texts.len,                   state.quit_early,                        widget.decorations.original_ids.len,
                        widget.decorations.modified_ids.len, widget.zones.original.records.items.len, widget.zones.modified.records.items.len, peak,
                        benchPeakRssBytes(),
                    },
                );
                if (item.pattern == .many and budget == 0 and !moves) {
                    try benchNativeDiffInteractions(wb, tab, io, &out, item.lines / 10);
                }
                if (budget == 5000 and !moves) {
                    var refresh: BenchDiffTimes = .{};
                    const refreshed = try benchNativeDiffOpen(wb, io, item.path, true, &refresh, &out);
                    try std.testing.expectEqual(tab, refreshed);
                    std.debug.print("[bench] diff-refresh n={d} case={s} total={d}us acquisition={d}us cache_hit={}\n", .{ item.lines, @tagName(item.pattern), refresh.total_us, refresh.acquisition_us.load(.acquire), refresh.cache_hit });
                }
                _ = try wb.closeActive();
                try std.testing.expectEqual(baseline_tabs, wb.tabCount());
                while (wb.window_events.nextTimeout(time_compat.milliTimestamp(), 1) == 0) _ = wb.window_events.dispatch(time_compat.milliTimestamp());
            }
        }
    }
}
