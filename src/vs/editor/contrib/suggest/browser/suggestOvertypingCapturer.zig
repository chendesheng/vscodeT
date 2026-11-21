// Port of `src/vs/editor/contrib/suggest/browser/suggestOvertypingCapturer.ts`.
//
// Terminal adaptation: the TUI has no `onWillType` event, so the app calls
// `capture` immediately before dispatching a typing key. Locking mirrors
// upstream: it is locked while the suggest widget is open.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Range = @import("../../../common/core/range.zig").Range;
const variables = @import("../../snippet/browser/snippetVariables.zig");

const max_selection_length: usize = 51200;

pub const OvertypingCapturer = struct {
    allocator: Allocator,
    last_overtyped: std.ArrayListUnmanaged(?Entry) = .empty,
    locked: bool = false,

    pub const Entry = struct {
        value: []u8,
        multiline: bool,
    };

    pub fn init(allocator: Allocator) OvertypingCapturer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OvertypingCapturer) void {
        self.clear();
        self.last_overtyped.deinit(self.allocator);
    }

    fn clear(self: *OvertypingCapturer) void {
        for (self.last_overtyped.items) |entry| {
            if (entry) |value| self.allocator.free(value.value);
        }
        self.last_overtyped.clearRetainingCapacity();
    }

    pub fn capture(self: *OvertypingCapturer, editor: *Editor) void {
        if (self.locked) return;

        const selections = editor.getModelSelections() catch return;
        defer self.allocator.free(selections);

        var will_overtype = false;
        for (selections) |selection| {
            if (!selection.isEmpty()) {
                will_overtype = true;
                break;
            }
        }
        if (!will_overtype) {
            self.clear();
            return;
        }

        self.clear();
        for (selections, 0..) |selection, index| {
            if (index >= 8) break;
            // Upstream passes the `Selection` itself, whose Range part is
            // normalized. A reversed (RTL) selection has its anchor after the
            // position, so using the raw selectionStart/position fields would
            // build an inverted range and underflow the length calculation.
            const range = Range.init(
                selection.startLineNumber,
                selection.startColumn,
                selection.endLineNumber,
                selection.endColumn,
            );
            if (editor.model.getValueLengthInRange(range, .TextDefined) > max_selection_length) {
                return;
            }
            var text = editor.model.getValueInRange(range, .TextDefined) catch return;
            defer text.deinit();
            const value = self.allocator.dupe(u8, text.items) catch return;
            self.last_overtyped.append(self.allocator, .{
                .value = value,
                .multiline = selection.startLineNumber != selection.endLineNumber,
            }) catch {
                self.allocator.free(value);
                return;
            };
        }
    }

    pub fn lock(self: *OvertypingCapturer) void {
        self.locked = true;
    }

    pub fn unlock(self: *OvertypingCapturer) void {
        self.locked = false;
    }

    pub fn getLastOvertypedInfo(self: *const OvertypingCapturer, idx: usize) ?variables.OvertypingInfo {
        if (idx >= self.last_overtyped.items.len) return null;
        const entry = self.last_overtyped.items[idx] orelse return null;
        return .{ .value = entry.value, .multiline = entry.multiline };
    }

    pub fn interface(self: *OvertypingCapturer) variables.OvertypingCapturer {
        return .{ .context = self, .get_last = getLastOvertypedInfoOpaque };
    }

    fn getLastOvertypedInfoOpaque(context: *anyopaque, idx: usize) ?variables.OvertypingInfo {
        const self: *OvertypingCapturer = @ptrCast(@alignCast(context));
        return self.getLastOvertypedInfo(idx);
    }
};
