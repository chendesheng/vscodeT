//! Debug-build benchmarks for the file-open/edit hot paths.
//!
//! The timing tests are opt-in so `zig build test` stays deterministic; the
//! viewport-tokenization contract test runs in the normal suite as well.
//! The `bench-open` build step sets `VSCODE_TEXTBUFFER_BENCH=1` and runs the
//! `benchmark:` filter:
//!
//!     zig build bench-open
//!
//! The default file is `src/tui/app.zig`; override with
//! `VSCODE_TEXTBUFFER_BENCH_FILE`. Timings use the monotonic clock and the
//! page allocator so the numbers reflect the app more closely than the
//! testing allocator does. They are diagnostics, not assertions: only the
//! structural checks (viewport tokenization, unattached model) assert.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const time_compat = @import("../vs/base/common/timeCompat.zig");
const Editor = @import("../vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Tab = @import("../vs/workbench/browser/parts/editor/editorPane.zig").Tab;
const FileEditorInput = @import("../vs/workbench/contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const Position = @import("../vs/editor/common/core/position.zig").Position;
const TextualDocumentHighlightProvider = @import("../vs/editor/contrib/wordHighlighter/browser/textualHighlightProvider.zig").TextualDocumentHighlightProvider;

const bench_env = "VSCODE_TEXTBUFFER_BENCH";
const file_env = "VSCODE_TEXTBUFFER_BENCH_FILE";
const default_file = "src/tui/app.zig";
const iterations: usize = 5;

fn enabled() bool {
    return std.c.getenv(bench_env) != null;
}

fn benchFile() []const u8 {
    const raw = std.c.getenv(file_env) orelse return default_file;
    return std.mem.span(raw);
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
            "total={d}us rebuilds={d} wraps={d} last_visible={d} tokens_accurate_first_paint={}",
            .{
                total_us,
                tab.view.rebuildCount(),
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
    for (0..10) |i| {
        const start = nowUs(io);
        try tab.editor.insertText("x");
        try tab.view.refresh();
        try tab.view.paint();
        last_us = nowUs(io) - start;
        best_us = @min(best_us, last_us);
        std.debug.print("[bench] edit {d}: {d}us\n", .{ i, last_us });
    }
    std.debug.print(
        "[bench] edit frame {s}: best={d}us last={d}us wraps_delta={d}\n",
        .{ path, best_us, last_us, tab.editor.view_lines.rebuildAllCount() - wraps_before },
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

    // Scrolling extends the tokenized range only to the new viewport.
    _ = editor.setTopViewLine(200);
    editor.ensureTokensVisible();
    const scrolled_last = editor.modelLineNumber(editor.topViewLine() + editor.textHeight() -| 1);
    try std.testing.expect(editor.model.tokenization().hasAccurateTokensForLine(scrolled_last));
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
