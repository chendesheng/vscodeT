// Port of src/vs/editor/browser/widget/diffEditor/features/movedBlocksLinesFeature.ts.
// Terminal adaptation: SVG tracks are fixed-cell orthogonal connectors. Each
// moved block owns a one-row model-anchored caption/Compare control.
const std = @import("std");
const ui = @import("ui");
const diff_model = @import("../diffEditorViewModel.zig");
const Editor = @import("../../codeEditor/codeEditorWidgetTerminal.zig").Editor;
const EditorZones = @import("../../../viewParts/viewZones/viewZones.zig").ViewZones;
const Alignment = @import("../components/diffEditorViewZones/diffEditorViewZones.zig").DiffEditorViewZones;
const browser = @import("../../../editorBrowser.zig");
const LineRange = @import("../../../../common/core/ranges/lineRange.zig").LineRange;
const offsets = @import("../../../../common/core/ranges/offsetRange.zig");
const EventHandler = @import("../../../../common/viewEventHandler.zig").ViewEventHandler;
const events = @import("../../../../common/viewEvents.zig");

pub const LinesLayout = struct {
    allocator: std.mem.Allocator,
    track_per_line: []usize,
    track_count: usize,

    pub fn compute(allocator: std.mem.Allocator, lines: []const offsets.OffsetRange) !LinesLayout {
        var tracks: [6]offsets.OffsetRangeSet = undefined;
        var track_count: usize = 0;
        defer for (tracks[0..track_count]) |*track| track.deinit();
        const result = try allocator.alloc(usize, lines.len);
        errdefer allocator.free(result);
        for (lines, result) |line, *index| {
            var candidate: ?usize = null;
            for (tracks[0..track_count], 0..) |*track, track_index| {
                if (!track.intersectsStrict(line)) {
                    candidate = track_index;
                    break;
                }
            }
            const track_index = candidate orelse blk: {
                if (track_count < tracks.len) {
                    tracks[track_count] = offsets.OffsetRangeSet.init(allocator);
                    track_count += 1;
                    break :blk track_count - 1;
                }
                // Pinned upstream uses findMaxIdx for the fallback track.
                var greatest: usize = 0;
                var greatest_intersection: usize = 0;
                for (tracks[0..track_count], 0..) |*track, i| {
                    const overlap = try track.intersectWithRangeLength(line);
                    if (overlap > greatest_intersection) {
                        greatest = i;
                        greatest_intersection = overlap;
                    }
                }
                break :blk greatest;
            };
            try tracks[track_index].addRange(line);
            index.* = track_index;
        }
        return .{ .allocator = allocator, .track_per_line = result, .track_count = track_count };
    }

    pub fn deinit(self: *LinesLayout) void {
        self.allocator.free(self.track_per_line);
    }
};

pub const Connection = struct {
    index: usize,
    from: usize,
    to: usize,
    track: usize = 0,

    fn range(self: Connection) offsets.OffsetRange {
        return offsets.OffsetRange.init(@min(self.from, self.to), @max(self.from, self.to));
    }

    fn lessThan(_: void, a: Connection, b: Connection) bool {
        const a_down = a.from > a.to;
        const b_down = b.from > b.to;
        if (a_down != b_down) return !a_down;
        return if (a_down) a.from < b.from else a.to > b.to;
    }
};

fn midpoint(editor: *Editor, range: LineRange) usize {
    const layout = editor.viewLayout();
    const start = editor.viewPositionOfModelPosition(.{ .lineNumber = range.startLineNumber, .column = 1 }).lineNumber;
    const first = layout.getVerticalOffsetForLineNumber(start, false);
    const last = if (range.endLineNumberExclusive > editor.model.getLineCount())
        layout.getVerticalOffsetAfterLineNumber(editor.viewLineCount(), true)
    else
        layout.getVerticalOffsetForLineNumber(editor.viewPositionOfModelPosition(.{ .lineNumber = range.endLineNumberExclusive, .column = 1 }).lineNumber, false);
    return @intFromFloat(@max(0, (first + last) / 2));
}

pub const MovedBlocksLinesFeature = struct {
    allocator: std.mem.Allocator,
    model: *diff_model.DiffEditorViewModel,
    alignment: *Alignment,
    original: Pane,
    modified: Pane,
    enabled: bool = false,
    updating: bool = false,
    last_focus_original: bool = false,
    connections: []Connection = &.{},
    track_count: usize = 0,
    move_listener: ?usize = null,
    initialized: bool = true,
    callback_context: *anyopaque,
    on_width_changed: *const fn (*anyopaque) void,
    on_compare: *const fn (*anyopaque, bool, usize) void,

    const Pane = struct {
        owner: *MovedBlocksLinesFeature,
        editor: *Editor,
        zones: *EditorZones,
        original: bool,
        handler: EventHandler = undefined,
        bindings: []Binding = &.{},
    };

    const Binding = struct {
        pane: *Pane,
        index: usize,
        id: ?[]const u8 = null,

        fn build(context: ?*anyopaque, doc: *ui.Document, info: browser.IViewZone.RenderInfo) anyerror!*ui.Node {
            const root = try doc.createElement(.div);
            errdefer doc.destroy(root);
            const caption = try doc.createElement(.div);
            _ = try root.appendChild(caption);
            const button = try doc.createElement(.div);
            _ = try root.appendChild(button);
            button.asElement().focusable = true;
            button.asElement().tab_index = 0;
            try button.setAttribute("role", "button");
            try button.setAttribute("class", "diff-moved-code-compare");
            try button.addEventListener(.{ .context = context, .mouse_down = onMouse, .key_down = onKey });
            try update(context, root, info);
            return root;
        }

        fn update(context: ?*anyopaque, root: *ui.Node, info: browser.IViewZone.RenderInfo) anyerror!void {
            const self: *Binding = @ptrCast(@alignCast(context.?));
            const move = self.pane.owner.model.stateRef().?.moved_texts[self.index];
            const other = if (self.pane.original) move.lineRangeMapping.modified else move.lineRangeMapping.original;
            const caption = root.first_child.?;
            const button = caption.next.?;
            const comparing = self.pane.owner.model.moved_text_to_compare == self.index;
            const button_label = if (comparing) "[✓Compare]" else "[Compare]";
            const button_width = @min(info.width, @as(usize, 10));
            root.setStyle(.{ .position = .relative, .width = .{ .cells = @floatFromInt(info.width) }, .height = .{ .cells = 1 }, .white_space = .pre, .overflow = .hidden });
            caption.setStyle(.{ .position = .absolute, .left = .{ .cells = 0 }, .top = .{ .cells = 0 }, .width = .{ .cells = @floatFromInt(info.width - button_width) }, .height = .{ .cells = 1 }, .overflow = .hidden });
            button.setStyle(.{ .position = .absolute, .left = .{ .cells = @floatFromInt(info.width - button_width) }, .top = .{ .cells = 0 }, .width = .{ .cells = @floatFromInt(button_width) }, .height = .{ .cells = 1 }, .overflow = .hidden });
            var label: [128]u8 = undefined;
            try caption.setTextContent(try std.fmt.bufPrint(&label, "Code moved{s} {s} line {d}-{d}", .{
                if (move.changes.len > 0) " with changes" else "",
                if (self.pane.original) "to" else "from",
                other.startLineNumber,
                other.endLineNumberExclusive - 1,
            }));
            try button.setTextContent(button_label);
            try button.setAttribute("aria-pressed", if (comparing) "true" else "false");
        }

        fn onMouse(context: ?*anyopaque, event: *ui.MouseEvent) void {
            if (event.button != .left) return;
            event.preventDefault();
            event.stopPropagation();
            const self: *Binding = @ptrCast(@alignCast(context.?));
            self.pane.owner.on_compare(self.pane.owner.callback_context, self.pane.original, self.index);
        }

        fn onKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
            switch (event.key) {
                .enter => {},
                .char => |c| if (c != ' ') return,
                .text => |text| if (!std.mem.eql(u8, text, " ")) return,
                else => return,
            }
            event.preventDefault();
            event.stopPropagation();
            const self: *Binding = @ptrCast(@alignCast(context.?));
            self.pane.owner.on_compare(self.pane.owner.callback_context, self.pane.original, self.index);
        }
    };

    pub fn init(self: *MovedBlocksLinesFeature, allocator: std.mem.Allocator, model: *diff_model.DiffEditorViewModel, alignment: *Alignment, original: *Editor, original_zones: *EditorZones, modified: *Editor, modified_zones: *EditorZones, context: *anyopaque, on_width: *const fn (*anyopaque) void, on_compare: *const fn (*anyopaque, bool, usize) void) !void {
        self.* = .{
            .allocator = allocator,
            .model = model,
            .alignment = alignment,
            .original = .{ .owner = self, .editor = original, .zones = original_zones, .original = true },
            .modified = .{ .owner = self, .editor = modified, .zones = modified_zones, .original = false },
            .callback_context = context,
            .on_width_changed = on_width,
            .on_compare = on_compare,
        };
        for ([_]*Pane{ &self.original, &self.modified }) |pane| {
            pane.handler = EventHandler.init(pane, .{ .onLineMappingChanged = onMapping, .onZonesChanged = onZones, .onConfigurationChanged = onConfiguration, .onFocusChanged = onFocus, .onCursorStateChanged = onCursor });
            pane.editor.addViewEventHandler(&pane.handler);
        }
        errdefer self.deinit();
        self.move_listener = try model.on_did_change_active_move.listen(self, onMoveChanged);
    }

    pub fn deinit(self: *MovedBlocksLinesFeature) void {
        if (!self.initialized) return;
        self.initialized = false;
        self.updating = true;
        if (self.move_listener) |id| self.model.on_did_change_active_move.unlisten(id);
        self.alignment.beginBatch();
        defer self.alignment.endBatch();
        for ([_]*Pane{ &self.original, &self.modified }) |pane| {
            pane.editor.removeViewEventHandler(&pane.handler);
            pane.zones.changeViewZones(pane, removeZones) catch {};
            self.allocator.free(pane.bindings);
        }
        self.allocator.free(self.connections);
    }

    fn removeZones(pane: *Pane, accessor: browser.IViewZoneChangeAccessor) anyerror!void {
        for (pane.bindings) |*binding| if (binding.id) |id| {
            try accessor.removeZone(id);
            binding.id = null;
        };
    }

    fn addZones(pane: *Pane, accessor: browser.IViewZoneChangeAccessor) anyerror!void {
        const moves = pane.owner.model.stateRef().?.moved_texts;
        for (pane.bindings) |*binding| {
            const move = moves[binding.index];
            const range = if (pane.original) move.lineRangeMapping.original else move.lineRangeMapping.modified;
            binding.id = try accessor.addZone(.{
                .after_line_number = range.startLineNumber - 1,
                .height_in_lines = 1,
                .show_in_hidden_areas = true,
                .suppress_mouse_down = true,
                .context = binding,
                .build = Binding.build,
                .update = Binding.update,
            });
        }
    }

    pub fn setEnabled(self: *MovedBlocksLinesFeature, enabled: bool) !void {
        if (self.enabled == enabled) return;
        self.enabled = enabled;
        self.updating = true;
        self.alignment.beginBatch();
        defer {
            self.alignment.endBatch();
            self.updating = false;
            if (self.enabled) self.refreshActiveMove();
        }
        for ([_]*Pane{ &self.original, &self.modified }) |pane| {
            try pane.zones.changeViewZones(pane, removeZones);
            self.allocator.free(pane.bindings);
            pane.bindings = &.{};
            if (enabled) {
                pane.bindings = try self.allocator.alloc(Binding, self.model.stateRef().?.moved_texts.len);
                for (pane.bindings, 0..) |*binding, i| binding.* = .{ .pane = pane, .index = i };
                try pane.zones.changeViewZones(pane, addZones);
            }
        }
        if (!enabled) {
            self.allocator.free(self.connections);
            self.connections = &.{};
            self.track_count = 0;
            self.model.setMovedTextToCompare(null);
            self.model.setMovedTextFromCursor(null);
            self.model.setHoveredMovedText(null);
        }
    }

    pub fn recomputeGeometry(self: *MovedBlocksLinesFeature) !void {
        if (!self.enabled or self.updating) return;
        const moves = self.model.stateRef().?.moved_texts;
        const result = try self.allocator.alloc(Connection, moves.len);
        errdefer self.allocator.free(result);
        for (moves, result, 0..) |move, *connection, index| {
            connection.* = .{ .index = index, .from = midpoint(self.original.editor, move.lineRangeMapping.original), .to = midpoint(self.modified.editor, move.lineRangeMapping.modified) };
        }
        std.mem.sort(Connection, result, {}, Connection.lessThan);
        const ranges = try self.allocator.alloc(offsets.OffsetRange, result.len);
        defer self.allocator.free(ranges);
        for (result, ranges) |connection, *range| range.* = connection.range();
        var layout = try LinesLayout.compute(self.allocator, ranges);
        defer layout.deinit();
        for (result, layout.track_per_line) |*connection, track| connection.track = track;
        self.allocator.free(self.connections);
        self.connections = result;
        const changed = self.track_count != layout.track_count;
        self.track_count = layout.track_count;
        if (changed) self.on_width_changed(self.callback_context);
    }

    pub fn width(self: *const MovedBlocksLinesFeature) usize {
        return if (self.enabled and self.track_count > 0) self.track_count + 1 else 0;
    }

    fn onMapping(context: *anyopaque, _: *const events.ViewLineMappingChangedEvent) bool {
        const pane: *Pane = @ptrCast(@alignCast(context));
        pane.owner.recomputeGeometry() catch {};
        return false;
    }
    fn onZones(context: *anyopaque, _: *const events.ViewZonesChangedEvent) bool {
        const pane: *Pane = @ptrCast(@alignCast(context));
        pane.owner.recomputeGeometry() catch {};
        return false;
    }
    fn onConfiguration(context: *anyopaque, _: *const events.ViewConfigurationChangedEvent) bool {
        const pane: *Pane = @ptrCast(@alignCast(context));
        pane.owner.recomputeGeometry() catch {};
        return false;
    }
    fn onFocus(context: *anyopaque, event: *const events.ViewFocusChangedEvent) bool {
        const pane: *Pane = @ptrCast(@alignCast(context));
        if (event.isFocused) {
            pane.owner.last_focus_original = pane.original;
            pane.owner.updateActiveMove(pane);
        }
        return false;
    }
    fn onCursor(context: *anyopaque, _: *const events.ViewCursorStateChangedEvent) bool {
        const pane: *Pane = @ptrCast(@alignCast(context));
        if (pane.owner.last_focus_original == pane.original) pane.owner.updateActiveMove(pane);
        return false;
    }

    pub fn refreshActiveMove(self: *MovedBlocksLinesFeature) void {
        self.updateActiveMove(if (self.last_focus_original) &self.original else &self.modified);
    }

    pub fn setFocusedSide(self: *MovedBlocksLinesFeature, original: bool) void {
        self.last_focus_original = original;
        self.refreshActiveMove();
    }

    fn updateActiveMove(self: *MovedBlocksLinesFeature, pane: *Pane) void {
        if (!self.enabled or self.updating) return;
        const position = pane.editor.modelCursorPosition();
        var active: ?usize = null;
        for (self.model.stateRef().?.moved_texts, 0..) |move, index| {
            const range = if (pane.original) move.lineRangeMapping.original else move.lineRangeMapping.modified;
            if (range.contains(position.lineNumber)) {
                active = index;
                break;
            }
        }
        self.model.setMovedTextFromCursor(active);
    }

    fn onMoveChanged(_: void, self: *MovedBlocksLinesFeature) anyerror!void {
        for ([_]*Pane{ &self.original, &self.modified }) |pane| {
            for (pane.bindings) |binding| if (binding.id) |id| pane.zones.invalidateZoneContent(id);
            if (pane.bindings.len > 0) pane.editor.emitViewEvent(.{ .ViewZonesChanged = .{} });
        }
    }

    pub fn paint(self: *MovedBlocksLinesFeature, grid: *ui.CellGrid, x: usize, y: usize, width_cells: usize, height: usize, normal: ui.Color, active_color: ui.Color) void {
        if (width_cells == 0 or height == 0) return;
        for (self.connections) |connection| {
            const from = @as(i64, @intCast(connection.from)) - @as(i64, @intCast(self.original.editor.scrollTop()));
            const to = @as(i64, @intCast(connection.to)) - @as(i64, @intCast(self.modified.editor.scrollTop()));
            const track = @min(connection.track, width_cells - 1);
            const color = if (self.model.activeMovedText() == connection.index) active_color else normal;
            const style: ui.cell.PaintStyle = .{ .fg = ui.cell.packColor(color) };
            if (from == to) {
                if (from >= 0 and from < @as(i64, @intCast(height))) {
                    const row = y + @as(usize, @intCast(from));
                    for (0..width_cells - 1) |col| grid.putCodepoint(x + col, row, '─', 1, style);
                    grid.putCodepoint(x + width_cells - 1, row, '▶', 1, style);
                }
                continue;
            }
            const top = @max(0, @min(from, to));
            const bottom = @min(@as(i64, @intCast(height - 1)), @max(from, to));
            if (top <= bottom) {
                var row = top;
                while (row <= bottom) : (row += 1) grid.putCodepoint(x + track, y + @as(usize, @intCast(row)), '│', 1, style);
            }
            if (from >= 0 and from < @as(i64, @intCast(height))) {
                const row = y + @as(usize, @intCast(from));
                for (0..track) |col| grid.putCodepoint(x + col, row, '─', 1, style);
                grid.putCodepoint(x + track, row, if (from < to) '┐' else '┘', 1, style);
            }
            if (to >= 0 and to < @as(i64, @intCast(height))) {
                const row = y + @as(usize, @intCast(to));
                grid.putCodepoint(x + track, row, if (from < to) '└' else '┌', 1, style);
                for (@min(track + 1, width_cells - 1)..width_cells - 1) |col| grid.putCodepoint(x + col, row, '─', 1, style);
                grid.putCodepoint(x + width_cells - 1, row, '▶', 1, style);
            }
        }
    }
};

test "moved blocks: LinesLayout reuses disjoint tracks and caps overlapping tracks" {
    const allocator = std.testing.allocator;
    const Range = offsets.OffsetRange;
    var layout = try LinesLayout.compute(allocator, &.{
        Range.init(0, 10), Range.init(10, 20), Range.init(5, 15),
        Range.init(5, 15), Range.init(5, 15),  Range.init(5, 15),
        Range.init(5, 15), Range.init(5, 15),
    });
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 6), layout.track_count);
    try std.testing.expectEqualSlices(usize, &.{ 0, 0, 1, 2, 3, 4, 5, 0 }, layout.track_per_line);
}
