// Port of `src/vs/editor/browser/widget/diffEditor/features/revertButtonsFeature.ts`.
// The terminal IGlyphMarginWidget presents one arrow cell and a tooltip; the
// upstream selected-diff calculation, right-lane priority, visibility,
// lifetime and undoable edit callbacks are retained.
const std = @import("std");
const ui = @import("ui");
const browser = @import("../../../editorBrowser.zig");
const Editor = @import("../../codeEditor/codeEditorWidgetTerminal.zig").Editor;
const TerminalViewHost = @import("../../codeEditor/terminalViewHost.zig").TerminalViewHost;
const vm = @import("../diffEditorViewModel.zig");
const gutter = @import("gutterFeature.zig");
const Range = @import("../../../../common/core/range.zig").Range;
const SelectionEvent = @import("../../../../common/cursorEvents.zig").ICursorSelectionChangedEvent;
const SignalSubscription = @import("../../../../../base/common/event.zig").SignalSubscription;

pub const RevertChange = union(enum) {
    hunk: vm.DetailedLineRangeMapping,
    selection: []const vm.RangeMapping,
};

pub const Target = struct {
    context: *anyopaque,
    revert: *const fn (*anyopaque, RevertChange, u32, u32) anyerror!void,
};

pub const RevertButtonsFeature = struct {
    allocator: std.mem.Allocator,
    model: *vm.DiffEditorViewModel,
    modified: *Editor,
    host: *TerminalViewHost,
    target: Target,
    buttons: std.ArrayList(*RevertButton) = .empty,
    selection_listener: ?SignalSubscription = null,
    enabled: bool = false,
    selected_active: bool = false,
    next_id: usize = 0,

    pub fn init(self: *RevertButtonsFeature, allocator: std.mem.Allocator, model: *vm.DiffEditorViewModel, modified: *Editor, host: *TerminalViewHost, target: Target) !void {
        self.* = .{ .allocator = allocator, .model = model, .modified = modified, .host = host, .target = target };
        self.selection_listener = try modified.on_did_change_cursor_selection.listenDisposable(self, onSelectionChanged);
    }

    pub fn deinit(self: *RevertButtonsFeature) void {
        if (self.selection_listener) |listener| listener.dispose();
        self.selection_listener = null;
        self.clear();
        self.buttons.deinit(self.allocator);
    }

    fn clear(self: *RevertButtonsFeature) void {
        for (self.buttons.items) |button| {
            self.host.removeGlyphMarginWidget(button.id);
            button.destroy(self.allocator);
        }
        self.buttons.clearRetainingCapacity();
        self.selected_active = false;
    }

    pub fn setEnabled(self: *RevertButtonsFeature, enabled: bool) !void {
        if (self.enabled == enabled) return;
        self.enabled = enabled;
        try self.update();
    }

    fn onSelectionChanged(event: SelectionEvent, self: *RevertButtonsFeature) !void {
        if (!self.enabled) return;
        var all_empty = event.selection.isEmpty();
        for (event.secondarySelections) |selection| all_empty = all_empty and selection.isEmpty();
        if (!self.selected_active and all_empty) return;
        try self.update();
    }

    pub fn update(self: *RevertButtonsFeature) !void {
        self.clear();
        if (!self.enabled) return;
        const state = self.model.stateRef() orelse return;
        if (self.model.moved_text_to_compare != null) return;
        const selections = try self.modified.getSelections();
        defer self.modified.allocator.free(selections);
        var selected = try gutter.selectedDiffs(self.allocator, state.mappings, selections);
        defer selected.deinit(self.allocator);
        if (selected.range_mappings.len > 0) {
            self.selected_active = true;
            try self.add(selections[selections.len - 1].positionLineNumber, .{ .selection = selected.range_mappings });
        }
        var selected_index: usize = 0;
        for (state.mappings, 0..) |mapping, index| {
            if (selected_index < selected.mapping_indices.len and selected.mapping_indices[selected_index] == index) {
                selected_index += 1;
                continue;
            }
            const change = mapping.line_range_mapping;
            if (change.modified.isEmpty() or change.inner_changes == null) continue;
            try self.add(change.modified.startLineNumber, .{ .hunk = change });
        }
    }

    fn add(self: *RevertButtonsFeature, line: usize, change: RevertChange) !void {
        try self.buttons.ensureUnusedCapacity(self.allocator, 1);
        const button = try self.allocator.create(RevertButton);
        errdefer self.allocator.destroy(button);
        const id = try std.fmt.allocPrint(self.allocator, "revertButton{d}", .{self.next_id});
        self.next_id += 1;
        errdefer self.allocator.free(id);
        const owned: RevertChange = switch (change) {
            .hunk => |mapping| .{ .hunk = .{ .original = mapping.original, .modified = mapping.modified, .inner_changes = null } },
            .selection => |mappings| .{ .selection = try self.allocator.dupe(vm.RangeMapping, mappings) },
        };
        errdefer if (owned == .selection) self.allocator.free(owned.selection);
        button.* = .{ .id = id, .line = line, .change = owned, .target = self.target, .original_version = self.model.model.original.getVersionId(), .modified_version = self.model.model.modified.getVersionId() };
        try self.host.addGlyphMarginWidget(button.interface());
        self.buttons.appendAssumeCapacity(button);
    }
};

pub const RevertButton = struct {
    id: []u8,
    line: usize,
    change: RevertChange,
    target: Target,
    original_version: u32,
    modified_version: u32,
    pressed: bool = false,

    fn destroy(self: *RevertButton, allocator: std.mem.Allocator) void {
        if (self.change == .selection) allocator.free(self.change.selection);
        allocator.free(self.id);
        allocator.destroy(self);
    }

    pub fn interface(self: *RevertButton) browser.IGlyphMarginWidget {
        return .{ .context = self, .get_id = getId, .get_position = getPosition, .get_presentation = getPresentation, .handle_mouse = handleMouse };
    }

    fn getId(context: *anyopaque) []const u8 {
        const self: *RevertButton = @ptrCast(@alignCast(context));
        return self.id;
    }

    fn getPosition(context: *anyopaque) browser.IGlyphMarginWidgetPosition {
        const self: *RevertButton = @ptrCast(@alignCast(context));
        return .{ .lane = .Right, .range = Range.init(self.line, 1, self.line, 1), .zIndex = 10001 };
    }

    fn getPresentation(context: *anyopaque) browser.IGlyphMarginWidget.Presentation {
        const self: *RevertButton = @ptrCast(@alignCast(context));
        return .{ .codepoint = '→', .color = .{ .r = 180, .g = 180, .b = 180 }, .class_name = "revertButton", .tooltip = if (self.change == .selection) "Revert Selected Changes" else "Revert Change" };
    }

    fn handleMouse(context: *anyopaque, event: *ui.MouseEvent) !bool {
        const self: *RevertButton = @ptrCast(@alignCast(context));
        if (event.button == .right) return false;
        const run = switch (event.kind) {
            .down => blk: {
                self.pressed = event.button == .left;
                break :blk false;
            },
            .up => blk: {
                const pressed = self.pressed;
                self.pressed = false;
                break :blk pressed and event.button == .left;
            },
            .click => event.button == .left,
            else => return false,
        };
        event.preventDefault();
        event.stopPropagation();
        if (run) {
            // A synchronous model update can dispose this specific button.
            // Copy the invocation before the edit and do not access it again.
            const target = self.target;
            try target.revert(target.context, self.change, self.original_version, self.modified_version);
        }
        return true;
    }
};
