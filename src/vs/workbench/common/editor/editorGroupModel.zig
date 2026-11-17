// Port of `src/vs/workbench/common/editor/editorGroupModel.ts`.
//
// This is the tab model: it owns the ordered editor list, the MRU order, the
// selection, preview/pinned/sticky/transient state and emits the group change
// events the tab view listens to. It is independent of the editor widget so
// the TUI can keep one model per editor group and paint it however it wants.
//
// Deliberate Zig adaptations:
// - Methods return errors because `Emitter.fire` is fallible in this port.
// - `EditorInput` is a struct rather than a class; the model only depends on
//   its public contract (`matches`, `isDirty`, the change events).
// - The configuration service is replaced by `Configuration`; the caller
//   updates `config` and calls `onConfigurationUpdated` when it changes.
// - Serialization/deserialization and side-by-side inputs need the editor
//   factory registry and `SideBySideEditorInput`, which are not ported yet;
//   the `SerializedEditorGroupModel` types are kept for that follow-up.
// - `EditorOpenOptions.index` is an `isize` so negative indexes can be
//   clamped exactly like upstream `moveEditor`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../base/common/event.zig").Emitter;
const editor = @import("../editor.zig");
const editor_input = @import("editorInput.zig");
const editor_factory = @import("editorFactory.zig");
const side_by_side = @import("sideBySideEditorInput.zig");

const EditorInput = editor_input.EditorInput;
const Candidate = editor_input.Candidate;
const GroupIdentifier = editor.GroupIdentifier;
const GroupModelChangeKind = editor.GroupModelChangeKind;
const EditorsOrder = editor.EditorsOrder;
const MatchEditorOptions = editor.MatchEditorOptions;

pub const EditorOpenPositioning = enum { left, right, first, last };

/// Terminal adaptation of the two `workbench.editor` settings the model reads.
pub const Configuration = struct {
    editor_open_positioning: EditorOpenPositioning = .right,
    focus_recent_editor_after_close: bool = true,
};

pub const EditorOpenOptions = struct {
    pinned: bool = false,
    sticky: bool = false,
    transient: bool = false,
    active: bool = false,
    inactive_selection: []const *EditorInput = &.{},
    index: ?isize = null,
    support_side_by_side: ?editor.SideBySideEditor = null,
};

pub const EditorOpenResult = struct {
    editor: *EditorInput,
    is_new: bool,
};

pub const EditorChange = struct {
    editor: *EditorInput,
    editor_index: usize,
};

pub const EditorCloseChange = struct {
    editor: *EditorInput,
    editor_index: usize,
    context: editor.EditorCloseContext,
    sticky: bool,
};

pub const EditorMoveChange = struct {
    editor: *EditorInput,
    old_editor_index: usize,
    editor_index: usize,
};

/// Mirrors upstream `IGroupModelChangeEvent` and its typed variants. Zig's
/// tagged union carries the payload only on the variants that have one.
pub const GroupModelChangeEvent = union(GroupModelChangeKind) {
    GROUP_ACTIVE: void,
    GROUP_INDEX: void,
    GROUP_LABEL: void,
    GROUP_LOCKED: void,
    EDITORS_SELECTION: void,
    EDITOR_OPEN: EditorChange,
    EDITOR_CLOSE: EditorCloseChange,
    EDITOR_MOVE: EditorMoveChange,
    EDITOR_ACTIVE: EditorChange,
    EDITOR_LABEL: EditorChange,
    EDITOR_CAPABILITIES: EditorChange,
    EDITOR_PIN: EditorChange,
    EDITOR_TRANSIENT: EditorChange,
    EDITOR_STICKY: EditorChange,
    EDITOR_DIRTY: EditorChange,
    EDITOR_WILL_DISPOSE: EditorChange,
};

pub const EditorCloseResult = struct {
    editor: *EditorInput,
    editor_index: usize,
    context: editor.EditorCloseContext,
    sticky: bool,
};

pub const FindEditorResult = struct {
    editor: *EditorInput,
    index: usize,
};

/// Mirrors upstream's `EditorInput | number` overloads.
pub const EditorOrIndex = union(enum) {
    editor: *EditorInput,
    index: usize,
};

/// Mirrors upstream `ISerializedEditorInput`.
pub const SerializedEditorInput = struct {
    id: []u8,
    value: []u8,
};

/// Mirrors upstream `ISerializedEditorGroupModel`. Slices are owned by the
/// value; call `deinit` with the allocator used for `serialize`.
pub const SerializedEditorGroupModel = struct {
    id: GroupIdentifier,
    locked: bool = false,
    editors: []SerializedEditorInput = &.{},
    mru: []usize = &.{},
    preview: ?usize = null,
    sticky: ?isize = null,

    pub fn deinit(self: *SerializedEditorGroupModel, allocator: Allocator) void {
        for (self.editors) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.value);
        }
        if (self.editors.len > 0) allocator.free(self.editors);
        if (self.mru.len > 0) allocator.free(self.mru);
        self.* = .{ .id = self.id };
    }
};

var next_group_id: GroupIdentifier = 0;

fn allocateGroupId() GroupIdentifier {
    const id = next_group_id;
    next_group_id +%= 1;
    return id;
}

const EditorListeners = struct {
    group: *EditorGroupModel,
    editor: *EditorInput,
    dirty_id: Emitter(void).ListenerId,
    label_id: Emitter(void).ListenerId,
    capabilities_id: Emitter(void).ListenerId,
    will_dispose_id: Emitter(void).ListenerId,
};

pub const EditorGroupModel = struct {
    allocator: Allocator,
    id: GroupIdentifier,
    config: Configuration,

    editors: std.array_list.Managed(*EditorInput),
    mru: std.array_list.Managed(*EditorInput),
    selection: std.array_list.Managed(*EditorInput),
    transient: std.array_list.Managed(*EditorInput),
    editor_listeners: std.array_list.Managed(*EditorListeners),

    preview: ?*EditorInput = null,
    /// Index of the last sticky editor, or -1 when there is none.
    sticky: isize = -1,
    locked: bool = false,
    disposed: bool = false,

    on_did_model_change: Emitter(GroupModelChangeEvent),

    pub fn init(allocator: Allocator, config: Configuration) !EditorGroupModel {
        return .{
            .allocator = allocator,
            .id = allocateGroupId(),
            .config = config,
            .editors = std.array_list.Managed(*EditorInput).init(allocator),
            .mru = std.array_list.Managed(*EditorInput).init(allocator),
            .selection = std.array_list.Managed(*EditorInput).init(allocator),
            .transient = std.array_list.Managed(*EditorInput).init(allocator),
            .editor_listeners = std.array_list.Managed(*EditorListeners).init(allocator),
            .on_did_model_change = Emitter(GroupModelChangeEvent).init(allocator),
        };
    }

    pub fn deinit(self: *EditorGroupModel) void {
        self.dispose();

        self.editor_listeners.deinit();
        self.transient.deinit();
        self.selection.deinit();
        self.mru.deinit();
        self.editors.deinit();
        self.on_did_model_change.deinit();
    }

    /// Mirrors upstream `dispose`: stop listening to editor inputs and clear
    /// the transient set. The model's own arrays stay alive for `deinit`.
    pub fn dispose(self: *EditorGroupModel) void {
        if (self.disposed) return;
        self.disposed = true;

        for (self.editor_listeners.items) |listeners| {
            self.unlisten(listeners);
            self.allocator.destroy(listeners);
        }
        self.editor_listeners.clearRetainingCapacity();
        self.transient.clearRetainingCapacity();
    }

    pub fn isDisposed(self: *const EditorGroupModel) bool {
        return self.disposed;
    }

    pub fn count(self: *const EditorGroupModel) usize {
        return self.editors.items.len;
    }

    pub fn stickyCount(self: *const EditorGroupModel) usize {
        if (self.sticky < 0) return 0;
        return @intCast(self.sticky + 1);
    }

    pub fn isLocked(self: *const EditorGroupModel) bool {
        return self.locked;
    }

    pub fn lock(self: *EditorGroupModel, locked: bool) !void {
        if (self.locked == locked) return;
        self.locked = locked;
        try self.fire(.{ .GROUP_LOCKED = {} });
    }

    pub fn activeEditor(self: *const EditorGroupModel) ?*EditorInput {
        return if (self.selection.items.len > 0) self.selection.items[0] else null;
    }

    pub fn previewEditor(self: *const EditorGroupModel) ?*EditorInput {
        return self.preview;
    }

    /// Returns an allocated copy; the caller owns the slice.
    pub fn getEditors(
        self: *const EditorGroupModel,
        allocator: Allocator,
        order: EditorsOrder,
        exclude_sticky: bool,
    ) ![]*EditorInput {
        const source = switch (order) {
            .MOST_RECENTLY_ACTIVE => self.mru.items,
            .SEQUENTIAL => self.editors.items,
        };

        if (!exclude_sticky) {
            return allocator.dupe(*EditorInput, source);
        }

        var result = std.array_list.Managed(*EditorInput).init(allocator);
        errdefer result.deinit();

        switch (order) {
            .MOST_RECENTLY_ACTIVE => {
                for (source) |input| {
                    if (!self.isSticky(.{ .editor = input })) try result.append(input);
                }
            },
            .SEQUENTIAL => {
                const start: usize = if (self.sticky >= 0)
                    @min(@as(usize, @intCast(self.sticky + 1)), source.len)
                else
                    0;
                for (source[start..]) |input| try result.append(input);
            },
        }

        return result.toOwnedSlice();
    }

    pub fn getEditorByIndex(self: *const EditorGroupModel, index: usize) ?*EditorInput {
        if (index >= self.editors.items.len) return null;
        return self.editors.items[index];
    }

    /// Selected editors in sequential order, like upstream.
    pub fn selectedEditors(self: *const EditorGroupModel, allocator: Allocator) ![]*EditorInput {
        var result = std.array_list.Managed(*EditorInput).init(allocator);
        errdefer result.deinit();
        for (self.editors.items) |input| {
            if (self.doIsSelected(input)) try result.append(input);
        }
        return result.toOwnedSlice();
    }

    pub fn isActive(self: *const EditorGroupModel, candidate: Candidate) bool {
        return self.matchesEditor(self.activeEditor(), candidate, .{});
    }

    pub fn isFirst(self: *const EditorGroupModel, candidate: ?*EditorInput) bool {
        const input = candidate orelse return false;
        if (self.editors.items.len == 0) return false;
        return self.matchesEditor(self.editors.items[0], .{ .input = input }, .{});
    }

    pub fn isLast(self: *const EditorGroupModel, candidate: ?*EditorInput) bool {
        const input = candidate orelse return false;
        if (self.editors.items.len == 0) return false;
        return self.matchesEditor(self.editors.items[self.editors.items.len - 1], .{ .input = input }, .{});
    }

    pub fn isPinned(self: *const EditorGroupModel, candidate: EditorOrIndex) bool {
        const input = self.resolveEditor(candidate) orelse return false;
        return !self.matchesEditor(self.preview, .{ .input = input }, .{});
    }

    pub fn isSticky(self: *const EditorGroupModel, candidate: EditorOrIndex) bool {
        if (self.sticky < 0) return false;

        const index = switch (candidate) {
            .index => |index| index,
            .editor => |input| self.indexOf(.{ .input = input }) orelse return false,
        };
        if (index >= self.editors.items.len) return false;
        return @as(isize, @intCast(index)) <= self.sticky;
    }

    pub fn isSelected(self: *const EditorGroupModel, candidate: EditorOrIndex) bool {
        const input = self.resolveEditor(candidate) orelse return false;
        return self.doIsSelected(input);
    }

    pub fn isTransient(self: *const EditorGroupModel, candidate: EditorOrIndex) bool {
        const input = self.resolveEditor(candidate) orelse return false;
        for (self.transient.items) |transient| {
            if (transient == input) return true;
        }
        return false;
    }

    pub fn findEditor(
        self: *const EditorGroupModel,
        candidate: ?*EditorInput,
        options: MatchEditorOptions,
    ) ?FindEditorResult {
        const input = candidate orelse return null;
        const index = self.indexOfIn(.{ .input = input }, self.editors.items, options) orelse return null;
        return .{ .editor = self.editors.items[index], .index = index };
    }

    pub fn indexOf(self: *const EditorGroupModel, candidate: Candidate) ?usize {
        return self.indexOfIn(candidate, self.editors.items, .{});
    }

    pub fn indexOfWith(self: *const EditorGroupModel, candidate: Candidate, options: MatchEditorOptions) ?usize {
        return self.indexOfIn(candidate, self.editors.items, options);
    }

    pub fn indexOfIn(
        self: *const EditorGroupModel,
        candidate: Candidate,
        editors: []const *EditorInput,
        options: MatchEditorOptions,
    ) ?usize {
        var index: ?usize = null;
        const candidate_is_side_by_side = switch (candidate) {
            .input => |other| side_by_side.is(other) != null,
            .untyped => false,
        };
        for (editors, 0..) |input, i| {
            if (self.matchesEditor(input, candidate, options)) {
                index = i;
                // Prefer a later direct match over an earlier side-by-side match.
                if (options.support_side_by_side != null and side_by_side.is(input) != null and !candidate_is_side_by_side) continue;
                break;
            }
        }
        return index;
    }

    pub fn contains(self: *const EditorGroupModel, candidate: Candidate, options: MatchEditorOptions) bool {
        return self.indexOfWith(candidate, options) != null;
    }

    /// Mirrors upstream `indexOf` with an explicit editor list.
    pub fn indexOfExact(self: *const EditorGroupModel, input: *EditorInput) ?usize {
        for (self.editors.items, 0..) |candidate, index| {
            if (candidate == input) return index;
        }
        return null;
    }

    pub fn openEditor(self: *EditorGroupModel, candidate: *EditorInput, options: EditorOpenOptions) !EditorOpenResult {
        const make_sticky = options.sticky or
            (if (options.index) |index| index >= 0 and self.isSticky(.{ .index = @intCast(index) }) else false);
        const make_pinned = options.pinned or options.sticky;
        const make_transient = options.transient;
        const current_active = self.activeEditor();
        const make_active = options.active or current_active == null or
            (!make_pinned and self.preview == current_active);

        const existing = self.findEditor(candidate, .{});

        if (existing == null) {
            const new_editor = candidate;
            // A previous close with `open_next = false` can leave the
            // selection pointing at an editor that is no longer in the group
            // (upstream behaves the same way); treat it like JS `indexOf` -1.
            const index_of_active: isize = if (current_active) |active|
                if (self.indexOf(.{ .input = active })) |index| @intCast(index) else -1
            else
                -1;

            var target_index: isize = 0;
            if (options.index) |index| {
                target_index = index;
            } else switch (self.config.editor_open_positioning) {
                .first => {
                    target_index = 0;
                    if (!make_sticky and self.isSticky(.{ .index = 0 })) {
                        target_index = self.sticky + 1;
                    }
                },
                .last => {
                    target_index = @intCast(self.editors.items.len);
                },
                .left => {
                    if (index_of_active == 0 or self.editors.items.len == 0) {
                        target_index = 0;
                    } else {
                        target_index = index_of_active;
                    }
                    if (!make_sticky and self.isStickyIndex(target_index)) {
                        target_index = self.sticky + 1;
                    }
                },
                .right => {
                    target_index = index_of_active + 1;
                    if (!make_sticky and self.isStickyIndex(target_index)) {
                        target_index = self.sticky + 1;
                    }
                },
            }

            // If the editor becomes sticky, increment our sticky index and
            // adjust the target to the end of the sticky editors.
            if (make_sticky) {
                self.sticky += 1;
                if (!self.isStickyIndex(target_index)) {
                    target_index = self.sticky;
                }
            }

            // Insert into our list of editors if pinned or we have no preview.
            if (make_pinned or self.preview == null) {
                try self.splice(self.clampIndex(target_index), false, new_editor);
            }

            if (make_transient) {
                try self.doSetTransient(new_editor, self.clampIndex(target_index), true);
            }

            if (!make_pinned) {
                if (self.preview) |preview| {
                    const index_of_preview = self.indexOf(.{ .input = preview }).?;
                    if (target_index > @as(isize, @intCast(index_of_preview))) {
                        target_index -= 1;
                    }
                    try self.replaceEditor(preview, new_editor, self.clampIndex(target_index), !make_active);
                }
                self.preview = new_editor;
            }

            try self.registerEditorListeners(new_editor);
            try self.fire(.{ .EDITOR_OPEN = .{
                .editor = new_editor,
                .editor_index = self.clampIndex(target_index),
            } });

            if (make_active) {
                try self.setSelection(new_editor, options.inactive_selection);
            } else if (current_active) |active| {
                try self.setSelection(active, options.inactive_selection);
            }

            return .{ .editor = new_editor, .is_new = true };
        }

        const existing_editor = existing.?.editor;
        const existing_index = existing.?.index;

        // Existing editors do not turn transient if they were not before.
        if (!make_transient) {
            try self.doSetTransient(existing_editor, existing_index, false);
        }

        if (make_pinned) {
            try self.doPin(existing_editor, existing_index);
        }

        if (make_active) {
            try self.setSelection(existing_editor, options.inactive_selection);
        } else if (self.activeEditor()) |active| {
            try self.setSelection(active, options.inactive_selection);
        }

        if (options.index) |index| {
            _ = try self.moveEditor(existing_editor, index);
        }

        if (make_sticky) {
            try self.doStick(existing_editor, self.indexOf(.{ .input = existing_editor }).?);
        }

        return .{ .editor = existing_editor, .is_new = false };
    }

    pub fn closeEditor(
        self: *EditorGroupModel,
        candidate: *EditorInput,
        context: editor.EditorCloseContext,
        open_next: bool,
    ) !?EditorCloseResult {
        const close_result = try self.doCloseEditor(candidate, context, open_next) orelse return null;

        try self.fire(.{ .EDITOR_CLOSE = .{
            .editor = close_result.editor,
            .editor_index = close_result.editor_index,
            .context = close_result.context,
            .sticky = close_result.sticky,
        } });
        self.unregisterEditorListeners(close_result.editor);

        return close_result;
    }

    pub fn moveEditor(self: *EditorGroupModel, candidate: *EditorInput, to_index: isize) !?*EditorInput {
        if (self.editors.items.len == 0) return null;

        var target_index = to_index;
        if (target_index >= @as(isize, @intCast(self.editors.items.len))) {
            target_index = @intCast(self.editors.items.len - 1);
        } else if (target_index < 0) {
            target_index = 0;
        }

        const index = self.indexOf(.{ .input = candidate }) orelse return null;
        if (target_index == @as(isize, @intCast(index))) return null;

        const input = self.editors.items[index];
        const sticky_before = self.sticky;

        if (self.isSticky(.{ .index = index }) and target_index > self.sticky) {
            self.sticky -= 1;
        } else if (!self.isSticky(.{ .index = index }) and target_index <= self.sticky) {
            self.sticky += 1;
        }

        _ = self.editors.orderedRemove(index);
        try self.editors.insert(self.clampIndex(target_index), input);

        try self.fire(.{ .EDITOR_MOVE = .{
            .editor = input,
            .old_editor_index = index,
            .editor_index = self.clampIndex(target_index),
        } });

        if (sticky_before != self.sticky) {
            try self.fire(.{ .EDITOR_STICKY = .{
                .editor = input,
                .editor_index = self.clampIndex(target_index),
            } });
        }

        return input;
    }

    pub fn setActive(self: *EditorGroupModel, candidate: ?*EditorInput) !?*EditorInput {
        const input = candidate orelse {
            try self.fire(.{ .GROUP_ACTIVE = {} });
            return null;
        };

        const result = self.findEditor(input, .{}) orelse return null;
        try self.doSetSelection(result.editor, result.index, &.{});
        return result.editor;
    }

    pub fn setSelection(
        self: *EditorGroupModel,
        active_selected_editor: *EditorInput,
        inactive_selected_editors: []const *EditorInput,
    ) !void {
        const result = self.findEditor(active_selected_editor, .{}) orelse return;

        var inactive = std.array_list.Managed(*EditorInput).init(self.allocator);
        defer inactive.deinit();

        for (inactive_selected_editors) |candidate| {
            const found = self.findEditor(candidate, .{}) orelse return;
            if (found.editor == result.editor) continue;
            var duplicate = false;
            for (inactive.items) |existing| {
                if (existing == found.editor) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) try inactive.append(found.editor);
        }

        try self.doSetSelection(result.editor, result.index, inactive.items);
    }

    pub fn setIndex(self: *EditorGroupModel, index: usize) !void {
        _ = index;
        try self.fire(.{ .GROUP_INDEX = {} });
    }

    pub fn setLabel(self: *EditorGroupModel, label: []const u8) !void {
        _ = label;
        try self.fire(.{ .GROUP_LABEL = {} });
    }

    pub fn pin(self: *EditorGroupModel, candidate: *EditorInput) !?*EditorInput {
        const result = self.findEditor(candidate, .{}) orelse return null;
        try self.doPin(result.editor, result.index);
        return result.editor;
    }

    pub fn unpin(self: *EditorGroupModel, candidate: *EditorInput) !?*EditorInput {
        const result = self.findEditor(candidate, .{}) orelse return null;
        try self.doUnpin(result.editor, result.index);
        return result.editor;
    }

    pub fn stick(self: *EditorGroupModel, candidate: *EditorInput) !?*EditorInput {
        const result = self.findEditor(candidate, .{}) orelse return null;
        try self.doStick(result.editor, result.index);
        return result.editor;
    }

    pub fn unstick(self: *EditorGroupModel, candidate: *EditorInput) !?*EditorInput {
        const result = self.findEditor(candidate, .{}) orelse return null;
        try self.doUnstick(result.editor, result.index);
        return result.editor;
    }

    pub fn setTransient(self: *EditorGroupModel, candidate: *EditorInput, transient: bool) !?*EditorInput {
        if (!transient and self.transient.items.len == 0) return null;

        const result = self.findEditor(candidate, .{}) orelse return null;
        try self.doSetTransient(result.editor, result.index, transient);
        return result.editor;
    }

    /// Mirrors upstream `serialize`. Editors without a registered serializer,
    /// or whose serializer currently declines, are omitted from the stored
    /// list; the preview and sticky indexes are adjusted for the omissions.
    pub fn serialize(
        self: *EditorGroupModel,
        allocator: Allocator,
        registry: *editor_factory.EditorFactoryRegistry,
    ) !SerializedEditorGroupModel {
        var serialized_editors = std.array_list.Managed(SerializedEditorInput).init(allocator);
        errdefer {
            for (serialized_editors.items) |entry| {
                allocator.free(entry.id);
                allocator.free(entry.value);
            }
            serialized_editors.deinit();
        }

        var serializable_editors = std.array_list.Managed(*EditorInput).init(allocator);
        defer serializable_editors.deinit();

        var serializable_preview: ?usize = null;
        var serializable_sticky = self.sticky;

        for (self.editors.items, 0..) |input, index| {
            var can_serialize = false;

            if (registry.getEditorSerializer(input)) |serializer| {
                if (serializer.canSerialize(serializer.context, input)) {
                    if (try serializer.serialize(serializer.context, input, allocator)) |value| {
                        can_serialize = true;
                        try serialized_editors.append(.{
                            .id = try allocator.dupe(u8, input.type_id),
                            .value = @constCast(value),
                        });
                        try serializable_editors.append(input);
                        if (self.preview == input) {
                            serializable_preview = serializable_editors.items.len - 1;
                        }
                    }
                }
            }

            if (!can_serialize and self.isSticky(.{ .index = index })) {
                serializable_sticky -= 1;
            }
        }

        var serializable_mru = std.array_list.Managed(usize).init(allocator);
        errdefer serializable_mru.deinit();
        for (self.mru.items) |input| {
            if (self.indexOfIn(.{ .input = input }, serializable_editors.items, .{})) |index| {
                try serializable_mru.append(index);
            }
        }

        return .{
            .id = self.id,
            .locked = self.locked,
            .editors = try serialized_editors.toOwnedSlice(),
            .mru = try serializable_mru.toOwnedSlice(),
            .preview = serializable_preview,
            .sticky = if (serializable_sticky >= 0) serializable_sticky else null,
        };
    }

    /// Mirrors upstream `deserialize`: restore editors through the registry,
    /// drop inputs that cannot be deserialized while keeping sticky indexes
    /// consistent, and rebuild the MRU/selection/preview state.
    pub fn deserialize(
        self: *EditorGroupModel,
        data: SerializedEditorGroupModel,
        registry: *editor_factory.EditorFactoryRegistry,
    ) !void {
        if (data.id > 0) {
            self.id = data.id;
            next_group_id = @max(next_group_id, data.id +% 1);
        }
        if (data.locked) self.locked = true;

        var sticky = data.sticky;

        for (data.editors, 0..) |serialized, index| {
            var restored: ?*EditorInput = null;
            if (registry.getEditorSerializerByType(serialized.id)) |serializer| {
                restored = serializer.deserialize(serializer.context, serialized.value) catch null;
            }

            if (restored) |input| {
                try self.registerEditorListeners(input);
                try self.editors.append(input);
            } else if (sticky != null and @as(isize, @intCast(index)) <= sticky.?) {
                sticky = sticky.? - 1;
            }
        }

        for (data.mru) |index| {
            if (index < self.editors.items.len) {
                try self.mru.append(self.editors.items[index]);
            }
        }

        if (self.mru.items.len > 0) {
            try self.selection.append(self.mru.items[0]);
        }

        if (data.preview) |index| {
            if (index < self.editors.items.len) {
                self.preview = self.editors.items[index];
            }
        }

        if (sticky) |value| {
            if (value >= 0) self.sticky = value;
        }
    }

    /// Upstream constructs the model with an optional serialized group. This
    /// is the same entry point for the terminal workbench.
    pub fn initFromSerialized(
        allocator: Allocator,
        config: Configuration,
        data: SerializedEditorGroupModel,
        registry: *editor_factory.EditorFactoryRegistry,
    ) !EditorGroupModel {
        var model = try EditorGroupModel.init(allocator, config);
        errdefer model.deinit();
        try model.deserialize(data, registry);
        return model;
    }

    /// Mirrors upstream `clone`: copies editors, MRU, selection, preview and
    /// sticky state, but not the transient or locked state. Listeners are
    /// re-registered so the clone re-emits dirty/label changes.
    pub fn clone(self: *EditorGroupModel) !*EditorGroupModel {
        const copy = try self.allocator.create(EditorGroupModel);
        errdefer self.allocator.destroy(copy);

        copy.* = try EditorGroupModel.init(self.allocator, self.config);
        errdefer copy.deinit();

        try copy.editors.appendSlice(self.editors.items);
        try copy.mru.appendSlice(self.mru.items);
        try copy.selection.appendSlice(self.selection.items);
        copy.preview = self.preview;
        copy.sticky = self.sticky;

        for (copy.editors.items) |input| {
            try copy.registerEditorListeners(input);
        }

        return copy;
    }

    pub fn destroy(self: *EditorGroupModel) void {
        self.deinit();
        self.allocator.destroy(self);
    }

    // -- internals ---------------------------------------------------------

    fn resolveEditor(self: *const EditorGroupModel, candidate: EditorOrIndex) ?*EditorInput {
        return switch (candidate) {
            .editor => |input| input,
            .index => |index| if (index < self.editors.items.len) self.editors.items[index] else null,
        };
    }

    fn clampIndex(self: *const EditorGroupModel, index: isize) usize {
        if (index < 0) return 0;
        return @min(@as(usize, @intCast(index)), self.editors.items.len);
    }

    fn isStickyIndex(self: *const EditorGroupModel, index: isize) bool {
        if (self.sticky < 0) return false;
        return index <= self.sticky;
    }

    fn doIsSelected(self: *const EditorGroupModel, input: *EditorInput) bool {
        for (self.selection.items) |selected| {
            if (selected == input) return true;
        }
        return false;
    }

    fn matchesEditor(
        self: *const EditorGroupModel,
        input: ?*EditorInput,
        candidate: Candidate,
        options: MatchEditorOptions,
    ) bool {
        const editor_input_value = input orelse return false;

        if (options.support_side_by_side) |support| {
            if (side_by_side.is(editor_input_value)) |composite| {
                const candidate_is_side_by_side = switch (candidate) {
                    .input => |other| side_by_side.is(other) != null,
                    .untyped => false,
                };
                if (!candidate_is_side_by_side) {
                    switch (support) {
                        .ANY => {
                            if (self.matchesEditor(composite.primary, candidate, options) or
                                self.matchesEditor(composite.secondary, candidate, options)) return true;
                        },
                        .BOTH => {
                            if (self.matchesEditor(composite.primary, candidate, options) and
                                self.matchesEditor(composite.secondary, candidate, options)) return true;
                        },
                        else => {},
                    }
                }
            }
        }

        const strict_equals = switch (candidate) {
            .input => |other| editor_input_value == other,
            .untyped => false,
        };

        if (options.strict_equals) return strict_equals;
        return strict_equals or editor_input_value.matches(candidate);
    }

    fn registerEditorListeners(self: *EditorGroupModel, input: *EditorInput) !void {
        for (self.editor_listeners.items) |listeners| {
            if (listeners.editor == input) return;
        }

        const listeners = try self.allocator.create(EditorListeners);
        errdefer self.allocator.destroy(listeners);

        listeners.* = .{
            .group = self,
            .editor = input,
            .dirty_id = undefined,
            .label_id = undefined,
            .capabilities_id = undefined,
            .will_dispose_id = undefined,
        };

        listeners.dirty_id = try input.on_did_change_dirty.listen(listeners, onEditorDirty);
        errdefer input.on_did_change_dirty.unlisten(listeners.dirty_id);
        listeners.label_id = try input.on_did_change_label.listen(listeners, onEditorLabel);
        errdefer input.on_did_change_label.unlisten(listeners.label_id);
        listeners.capabilities_id = try input.on_did_change_capabilities.listen(listeners, onEditorCapabilities);
        errdefer input.on_did_change_capabilities.unlisten(listeners.capabilities_id);
        listeners.will_dispose_id = try input.on_will_dispose.listen(listeners, onEditorWillDispose);
        errdefer input.on_will_dispose.unlisten(listeners.will_dispose_id);

        try self.editor_listeners.append(listeners);
    }

    fn unregisterEditorListeners(self: *EditorGroupModel, input: *EditorInput) void {
        for (self.editor_listeners.items, 0..) |listeners, index| {
            if (listeners.editor != input) continue;
            self.unlisten(listeners);
            self.allocator.destroy(listeners);
            _ = self.editor_listeners.orderedRemove(index);
            return;
        }
    }

    fn unlisten(self: *EditorGroupModel, listeners: *EditorListeners) void {
        _ = self;
        listeners.editor.on_did_change_dirty.unlisten(listeners.dirty_id);
        listeners.editor.on_did_change_label.unlisten(listeners.label_id);
        listeners.editor.on_did_change_capabilities.unlisten(listeners.capabilities_id);
        listeners.editor.on_will_dispose.unlisten(listeners.will_dispose_id);
    }

    fn replaceEditor(
        self: *EditorGroupModel,
        to_replace: *EditorInput,
        replace_with: *EditorInput,
        replace_index: usize,
        open_next: bool,
    ) !void {
        const close_result = try self.doCloseEditor(to_replace, .REPLACE, open_next);

        // Add the replacement before emitting the close event, as upstream
        // does, so a close listener cannot open the disposed editor.
        try self.splice(replace_index, false, replace_with);

        if (close_result) |result| {
            try self.fire(.{ .EDITOR_CLOSE = .{
                .editor = result.editor,
                .editor_index = result.editor_index,
                .context = result.context,
                .sticky = result.sticky,
            } });
            self.unregisterEditorListeners(result.editor);
        }
    }

    fn doCloseEditor(
        self: *EditorGroupModel,
        candidate: *EditorInput,
        context: editor.EditorCloseContext,
        open_next: bool,
    ) !?EditorCloseResult {
        const index = self.indexOf(.{ .input = candidate }) orelse return null;
        const input = self.editors.items[index];
        const was_sticky = self.isSticky(.{ .index = index });
        const is_active = self.activeEditor() == input;

        if (open_next and is_active) {
            if (self.mru.items.len > 1) {
                var new_active: *EditorInput = undefined;
                if (self.config.focus_recent_editor_after_close) {
                    new_active = self.mru.items[1];
                } else if (index == self.editors.items.len - 1) {
                    new_active = self.editors.items[index - 1];
                } else {
                    new_active = self.editors.items[index + 1];
                }

                var new_inactive = std.array_list.Managed(*EditorInput).init(self.allocator);
                defer new_inactive.deinit();
                for (self.selection.items) |selected| {
                    if (selected != input and selected != new_active) {
                        try new_inactive.append(selected);
                    }
                }
                const new_active_index = self.indexOf(.{ .input = new_active }).?;
                try self.doSetSelection(new_active, new_active_index, new_inactive.items);
            } else {
                try self.doSetSelection(null, null, &.{});
            }
        } else if (!is_active) {
            if (self.doIsSelected(input)) {
                var new_inactive = std.array_list.Managed(*EditorInput).init(self.allocator);
                defer new_inactive.deinit();
                const active = self.activeEditor();
                for (self.selection.items) |selected| {
                    if (selected != input and selected != active) {
                        try new_inactive.append(selected);
                    }
                }
                try self.doSetSelection(active, if (active) |value| self.indexOf(.{ .input = value }) else null, new_inactive.items);
            }
        }

        if (self.preview == input) {
            self.preview = null;
        }

        for (self.transient.items, 0..) |transient, transient_index| {
            if (transient == input) {
                _ = self.transient.orderedRemove(transient_index);
                break;
            }
        }

        try self.splice(index, true, null);

        return .{
            .editor = input,
            .editor_index = index,
            .context = context,
            .sticky = was_sticky,
        };
    }

    fn doSetSelection(
        self: *EditorGroupModel,
        active_selected_editor: ?*EditorInput,
        active_selected_editor_index: ?usize,
        inactive_selected_editors: []const *EditorInput,
    ) !void {
        const previous_active = self.activeEditor();

        var new_selection = std.array_list.Managed(*EditorInput).init(self.allocator);
        defer new_selection.deinit();

        if (active_selected_editor) |active| {
            try new_selection.append(active);
            for (inactive_selected_editors) |inactive| {
                if (inactive != active) try new_selection.append(inactive);
            }
        }

        const active_editor_changed = active_selected_editor != null and
            active_selected_editor_index != null and
            previous_active != active_selected_editor.?;

        const selection_changed = !samePointers(self.selection.items, new_selection.items);

        self.selection.clearRetainingCapacity();
        try self.selection.appendSlice(new_selection.items);

        if (active_editor_changed) {
            const active = active_selected_editor.?;
            const mru_index = self.indexOfIn(.{ .input = active }, self.mru.items, .{}) orelse 0;
            _ = self.mru.orderedRemove(mru_index);
            try self.mru.insert(0, active);

            try self.fire(.{ .EDITOR_ACTIVE = .{
                .editor = active,
                .editor_index = active_selected_editor_index.?,
            } });
        }

        if (active_editor_changed or selection_changed) {
            try self.fire(.{ .EDITORS_SELECTION = {} });
        }
    }

    fn doPin(self: *EditorGroupModel, input: *EditorInput, input_index: usize) !void {
        if (self.isPinned(.{ .editor = input })) return;

        _ = try self.setTransient(input, false);

        self.preview = null;

        try self.fire(.{ .EDITOR_PIN = .{
            .editor = input,
            .editor_index = input_index,
        } });
    }

    fn doUnpin(self: *EditorGroupModel, input: *EditorInput, input_index: usize) !void {
        if (!self.isPinned(.{ .editor = input })) return;

        const old_preview = self.preview;
        self.preview = input;

        try self.fire(.{ .EDITOR_PIN = .{
            .editor = input,
            .editor_index = input_index,
        } });

        if (old_preview) |preview| {
            _ = try self.closeEditor(preview, .UNPIN, true);
        }
    }

    fn doStick(self: *EditorGroupModel, input: *EditorInput, input_index: usize) !void {
        if (self.isSticky(.{ .index = input_index })) return;

        _ = try self.pin(input);

        const new_editor_index = self.sticky + 1;
        _ = try self.moveEditor(input, new_editor_index);

        self.sticky += 1;

        try self.fire(.{ .EDITOR_STICKY = .{
            .editor = input,
            .editor_index = @intCast(new_editor_index),
        } });
    }

    fn doUnstick(self: *EditorGroupModel, input: *EditorInput, input_index: usize) !void {
        if (!self.isSticky(.{ .index = input_index })) return;

        const new_editor_index = self.sticky;
        _ = try self.moveEditor(input, new_editor_index);

        self.sticky -= 1;

        try self.fire(.{ .EDITOR_STICKY = .{
            .editor = input,
            .editor_index = @intCast(new_editor_index),
        } });
    }

    fn doSetTransient(self: *EditorGroupModel, input: *EditorInput, input_index: usize, transient: bool) !void {
        if (transient) {
            for (self.transient.items) |existing| {
                if (existing == input) return;
            }
            try self.transient.append(input);
        } else {
            var found: ?usize = null;
            for (self.transient.items, 0..) |existing, index| {
                if (existing == input) {
                    found = index;
                    break;
                }
            }
            const index = found orelse return;
            _ = self.transient.orderedRemove(index);
        }

        try self.fire(.{ .EDITOR_TRANSIENT = .{
            .editor = input,
            .editor_index = input_index,
        } });
    }

    fn splice(self: *EditorGroupModel, index: usize, del: bool, input: ?*EditorInput) !void {
        const editor_to_delete_or_replace: ?*EditorInput = if (index < self.editors.items.len)
            self.editors.items[index]
        else
            null;

        if (del and index < self.editors.items.len and self.isSticky(.{ .index = index })) {
            self.sticky -= 1;
        }

        if (del) {
            if (input) |replacement| {
                self.editors.items[index] = replacement;
            } else {
                _ = self.editors.orderedRemove(index);
            }
        } else {
            try self.editors.insert(index, input.?);
        }

        if (!del and input != null) {
            if (self.mru.items.len == 0) {
                try self.mru.append(input.?);
            } else {
                try self.mru.insert(1, input.?);
            }
        } else if (editor_to_delete_or_replace) |to_remove| {
            const index_in_mru = self.indexOfIn(.{ .input = to_remove }, self.mru.items, .{}) orelse return;
            if (del and input == null) {
                _ = self.mru.orderedRemove(index_in_mru);
            } else if (del and input != null) {
                self.mru.items[index_in_mru] = input.?;
            }
        }
    }

    fn fire(self: *EditorGroupModel, event: GroupModelChangeEvent) !void {
        try self.on_did_model_change.fire(event);
    }
};

fn samePointers(a: []const *EditorInput, b: []const *EditorInput) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left != right) return false;
    }
    return true;
}

fn onEditorDirty(_: void, listeners: *EditorListeners) anyerror!void {
    const index = listeners.group.indexOfExact(listeners.editor) orelse return;
    try listeners.group.fire(.{ .EDITOR_DIRTY = .{
        .editor = listeners.editor,
        .editor_index = index,
    } });
}

fn onEditorLabel(_: void, listeners: *EditorListeners) anyerror!void {
    const index = listeners.group.indexOfExact(listeners.editor) orelse return;
    try listeners.group.fire(.{ .EDITOR_LABEL = .{
        .editor = listeners.editor,
        .editor_index = index,
    } });
}

fn onEditorCapabilities(_: void, listeners: *EditorListeners) anyerror!void {
    const index = listeners.group.indexOfExact(listeners.editor) orelse return;
    try listeners.group.fire(.{ .EDITOR_CAPABILITIES = .{
        .editor = listeners.editor,
        .editor_index = index,
    } });
}

fn onEditorWillDispose(_: void, listeners: *EditorListeners) anyerror!void {
    const index = listeners.group.indexOfExact(listeners.editor) orelse return;
    try listeners.group.fire(.{ .EDITOR_WILL_DISPOSE = .{
        .editor = listeners.editor,
        .editor_index = index,
    } });
}
