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
    const tab = try Tab.initFromInput(allocator, input);
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
                tab.view.renderCount(),
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
    const edit_perf = tab.view.perfCounters();
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

    const scroll_perf = tab.view.perfCounters();
    std.debug.print(
        "[bench] scroll frame {s}: line_best={d}us avg_refresh={d}us avg_paint={d}us page_best={d}us wheel_best={d}us renders={d} chrome_renders={d} chrome_ops=+{d}/~{d}/>{d}/-{d} syncs={d}\n",
        .{
            path,
            line_best,
            @divTrunc(line_refresh, @as(i64, @intCast(line_iterations))),
            @divTrunc(line_paint, @as(i64, @intCast(line_iterations))),
            page_best,
            wheel_best,
            tab.view.renderCount(),
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

    const now = time_compat.milliTimestamp();
    var start = nowUs(io);
    var background_polls: usize = 0;
    while (tab.editor.pollBackgroundTokenization() and background_polls < 100_000) background_polls += 1;
    const background_us = nowUs(io) - start;

    start = nowUs(io);
    const folded = tab.editor.pollFolding(now + 200);
    const folding_us = nowUs(io) - start;

    start = nowUs(io);
    const guides = tab.editor.pollBracketGuides(now + 200);
    const guides_us = nowUs(io) - start;

    std.debug.print(
        "[bench] deferred maintenance {s}: background={d}us(polls={d}) folding={d}us({}) bracket_guides={d}us({})\n",
        .{ path, background_us, background_polls, folding_us, folded, guides_us, guides },
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

        tab.onEditorChanged(time_compat.milliTimestamp());
        const refresh_start = nowUs(io);
        try tab.view.refresh();
        refresh_us_total += nowUs(io) - refresh_start;

        const render_start = nowUs(io);
        workbench.refreshStatus();
        try renderFrame(workbench, &out.writer);
        render_us_total += nowUs(io) - render_start;
        out.clearRetainingCapacity();

        best = @min(best, nowUs(io) - frame_start);
    }

    const workbench_perf = tab.view.perfCounters();
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
        _ = workbench.handleSidebarMouse(&wheel);
        workbench.refreshStatus();
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
