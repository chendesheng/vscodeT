//! Port of
//! `vscode/extensions/markdown-language-features/src/preview/topmostLineMonitor.ts`.
//!
//! Upstream throttles visible-range events with `setTimeout(50)`. The TUI host
//! advances that timer from its main loop; `poll(now)` is only the browser
//! timer adapter, not a feature polling loop.

const std = @import("std");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;

pub const TopmostLineMonitor = struct {
    throttle_ms: i64 = 50,
    pending_line: f64 = 0,
    has_pending: bool = false,
    due_ms: i64 = 0,
    previous_line: ?f64 = null,

    pub fn updateLine(self: *TopmostLineMonitor, line: f64, now_ms: i64) void {
        if (!self.has_pending) {
            self.due_ms = now_ms + self.throttle_ms;
        }
        self.pending_line = line;
        self.has_pending = true;
    }

    /// Fires the pending update when due. Returns the line to scroll to.
    pub fn poll(self: *TopmostLineMonitor, now_ms: i64) ?f64 {
        if (!self.has_pending or now_ms < self.due_ms) return null;
        self.has_pending = false;
        self.previous_line = self.pending_line;
        return self.pending_line;
    }

    pub fn nextTimeoutMs(self: *const TopmostLineMonitor, now_ms: i64) ?u32 {
        if (!self.has_pending) return null;
        const remaining = self.due_ms - now_ms;
        return @intCast(@max(remaining, 0));
    }

    pub fn setPreviousLine(self: *TopmostLineMonitor, line: f64) void {
        self.previous_line = line;
    }

    pub fn previous(self: *const TopmostLineMonitor) ?f64 {
        return self.previous_line;
    }
};

/// `getVisibleLine(editor)`: fractional 0-based line at the top of the
/// viewport, based on the first visible character of the first visible view
/// line. Wrapped continuation rows therefore produce a value above the
/// integer model line.
pub fn getVisibleLine(editor: *Editor) ?f64 {
    if (editor.viewLineCount() == 0 or editor.textHeight() == 0) return null;
    const view_line = editor.topViewLine();
    if (view_line == 0 or view_line > editor.viewLineCount()) return null;
    const model_line = editor.modelLineNumber(view_line);
    const line_length = editor.model.getLineLength(model_line);
    const model_column = editor.modelColumnOfViewPosition(view_line, 1);
    const character: usize = model_column -| 1;
    const progress: f64 = @as(f64, @floatFromInt(character)) / @as(f64, @floatFromInt(line_length + 2));
    return @as(f64, @floatFromInt(model_line -| 1)) + progress;
}

test "topmostLineMonitor: throttles and keeps the latest line" {
    var monitor = TopmostLineMonitor{};
    monitor.updateLine(1.5, 1000);
    try std.testing.expectEqual(@as(?f64, null), monitor.poll(1020));
    monitor.updateLine(2.5, 1030);
    try std.testing.expectEqual(@as(?u32, 20), monitor.nextTimeoutMs(1030));
    try std.testing.expectEqual(@as(?f64, 2.5), monitor.poll(1051));
    try std.testing.expectEqual(@as(?f64, 2.5), monitor.previous());
    try std.testing.expectEqual(@as(?f64, null), monitor.poll(1060));
}
