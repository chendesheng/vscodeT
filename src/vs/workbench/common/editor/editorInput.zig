// Port of `src/vs/workbench/common/editor/editorInput.ts`.
//
// The port keeps upstream's abstract-input contract (type id, resource, name,
// capabilities, dirty/label/capability events, save/revert/move hooks). Zig
// has no class inheritance, so the shared state and default behavior live in
// this `EditorInput` struct; a concrete input embeds it, sets the optional
// override hooks and exposes the embedded value to the editor group.
//
// Terminal adaptation: upstream resources are `URI`s. The TUI workbench uses a
// canonical path string until `src/vs/base/common/uri.zig` is ported, and
// `matches` compares those strings directly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../base/common/event.zig").Emitter;
const editor = @import("../editor.zig");

pub const GroupIdentifier = editor.GroupIdentifier;
pub const EditorInputCapabilities = editor.EditorInputCapabilities;
pub const Verbosity = editor.Verbosity;

/// Terminal adaptation of `IEditorCloseHandler`: the confirm step is provided
/// by the workbench shell rather than an async dialog service.
pub const IEditorCloseHandler = struct {
    context: *anyopaque,
    show_confirm: *const fn (context: *anyopaque) bool,
};

/// A typed input or an untyped resource input, mirroring the overload of
/// upstream `EditorInput#matches`.
pub const Candidate = union(enum) {
    input: *EditorInput,
    untyped: editor.UntypedEditorInput,
};

/// A save result mirrors upstream `EditorInput | IUntypedEditorInput | undefined`:
/// null means the save failed or was canceled.
pub const SaveResult = ?*EditorInput;

pub const EditorInput = struct {
    allocator: Allocator,

    /// Unique type identifier shared by all inputs of the same concrete kind.
    type_id: []const u8,

    /// Optional editor-id override used by untyped matching.
    editor_id: ?[]const u8 = null,

    /// Canonical resource used for identity checks. Not owned by the input.
    resource: ?[]const u8 = null,

    /// Preferred display name; upstream's default is `Editor <typeId>`.
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,

    capabilities: u32 = EditorInputCapabilities.Readonly,
    dirty: bool = false,
    saving: bool = false,
    disposed: bool = false,

    on_did_change_dirty: Emitter(void),
    on_did_change_label: Emitter(void),
    on_did_change_capabilities: Emitter(void),
    on_will_dispose: Emitter(void),

    close_handler: ?IEditorCloseHandler = null,

    /// Concrete input that embeds this value. Set by the concrete constructor so
    /// override hooks can recover their own type without parent-pointer casts.
    impl: ?*anyopaque = null,

    /// Optional overrides. A concrete input only sets the hooks whose upstream
    /// subclass overrides; everything else falls back to the base behavior.
    matches_fn: ?*const fn (self: *EditorInput, other: *EditorInput) bool = null,
    is_dirty_fn: ?*const fn (self: *const EditorInput) bool = null,
    save_fn: ?*const fn (self: *EditorInput, group: GroupIdentifier) anyerror!SaveResult = null,
    revert_fn: ?*const fn (self: *EditorInput, group: GroupIdentifier) anyerror!void = null,
    copy_fn: ?*const fn (self: *EditorInput) *EditorInput = null,
    can_move_fn: ?*const fn (self: *EditorInput, source: GroupIdentifier, target: GroupIdentifier) CanMoveResult = null,
    can_reopen_fn: ?*const fn (self: *const EditorInput) bool = null,
    dispose_fn: ?*const fn (self: *EditorInput) void = null,

    pub const CanMoveResult = union(enum) {
        yes,
        no: []const u8,
    };

    pub fn init(allocator: Allocator, type_id: []const u8) EditorInput {
        return .{
            .allocator = allocator,
            .type_id = type_id,
            .on_did_change_dirty = Emitter(void).init(allocator),
            .on_did_change_label = Emitter(void).init(allocator),
            .on_did_change_capabilities = Emitter(void).init(allocator),
            .on_will_dispose = Emitter(void).init(allocator),
        };
    }

    /// Releases the event emitters. Concrete inputs destroy their own storage.
    pub fn deinit(self: *EditorInput) void {
        self.on_did_change_dirty.deinit();
        self.on_did_change_label.deinit();
        self.on_did_change_capabilities.deinit();
        self.on_will_dispose.deinit();
    }

    pub fn getName(self: *const EditorInput) []const u8 {
        return self.name orelse self.type_id;
    }

    pub fn getDescription(self: *const EditorInput, verbosity: Verbosity) ?[]const u8 {
        _ = verbosity;
        return self.description;
    }

    pub fn getTitle(self: *const EditorInput, verbosity: Verbosity) []const u8 {
        _ = verbosity;
        return self.getName();
    }

    pub fn getLabelExtraClasses(self: *const EditorInput) []const []const u8 {
        _ = self;
        return &.{};
    }

    pub fn hasCapability(self: *const EditorInput, capability: u32) bool {
        if (capability == EditorInputCapabilities.None) {
            return self.capabilities == EditorInputCapabilities.None;
        }
        return (self.capabilities & capability) != 0;
    }

    pub fn isReadonly(self: *const EditorInput) bool {
        return self.hasCapability(EditorInputCapabilities.Readonly);
    }

    pub fn isDirty(self: *const EditorInput) bool {
        if (self.is_dirty_fn) |is_dirty_fn| return is_dirty_fn(self);
        return self.dirty;
    }

    pub fn isModified(self: *const EditorInput) bool {
        return self.isDirty();
    }

    pub fn isSaving(self: *const EditorInput) bool {
        return self.saving;
    }

    pub fn isDisposed(self: *const EditorInput) bool {
        return self.disposed;
    }

    /// Mirrors upstream `EditorInput#matches`. Side-by-side matching is handled
    /// by the group model once `SideBySideEditorInput` is ported.
    pub fn matches(self: *EditorInput, candidate: Candidate) bool {
        return switch (candidate) {
            .input => |other| if (self.matches_fn) |matches_fn|
                matches_fn(self, other)
            else
                self == other,
            .untyped => |other| self.matchesUntyped(other),
        };
    }

    pub fn matchesUntyped(self: *const EditorInput, other: editor.UntypedEditorInput) bool {
        if (self.editor_id != null and other.editor_id != null and
            !std.mem.eql(u8, self.editor_id.?, other.editor_id.?))
        {
            return false;
        }

        const resource = self.resource orelse return false;
        const other_resource = other.resource orelse return false;
        return std.mem.eql(u8, resource, other_resource);
    }

    /// Fires the dirty event. The concrete input owns the `dirty` field; the
    /// test input uses this to emulate upstream's `setDirty()` helper.
    pub fn fireDirty(self: *EditorInput) !void {
        try self.on_did_change_dirty.fire({});
    }

    pub fn setDirty(self: *EditorInput, dirty: bool) !void {
        if (self.dirty == dirty) return;
        self.dirty = dirty;
        try self.on_did_change_dirty.fire({});
    }

    pub fn fireLabel(self: *EditorInput) !void {
        try self.on_did_change_label.fire({});
    }

    pub fn setCapabilities(self: *EditorInput, capabilities: u32) !void {
        if (self.capabilities == capabilities) return;
        self.capabilities = capabilities;
        try self.on_did_change_capabilities.fire({});
    }

    pub fn resolve(self: *EditorInput) anyerror!?*anyopaque {
        _ = self;
        return null;
    }

    pub fn save(self: *EditorInput, group: GroupIdentifier) anyerror!SaveResult {
        if (self.save_fn) |save_fn| return save_fn(self, group);
        return self;
    }

    pub fn saveAs(self: *EditorInput, group: GroupIdentifier) anyerror!SaveResult {
        if (self.save_fn) |save_fn| return save_fn(self, group);
        return self;
    }

    pub fn revert(self: *EditorInput, group: GroupIdentifier) anyerror!void {
        if (self.revert_fn) |revert_fn| return revert_fn(self, group);
    }

    pub fn copy(self: *EditorInput) *EditorInput {
        if (self.copy_fn) |copy_fn| return copy_fn(self);
        return self;
    }

    pub fn canMove(self: *EditorInput, source: GroupIdentifier, target: GroupIdentifier) CanMoveResult {
        if (self.can_move_fn) |can_move_fn| return can_move_fn(self, source, target);
        return .yes;
    }

    pub fn canReopen(self: *const EditorInput) bool {
        if (self.can_reopen_fn) |can_reopen_fn| return can_reopen_fn(self);
        return true;
    }

    /// Mirrors upstream `dispose`: fire `onWillDispose` once, then mark the
    /// input disposed. The concrete owner releases memory separately.
    pub fn dispose(self: *EditorInput) void {
        if (self.disposed) return;
        self.on_will_dispose.fire({}) catch {};
        self.disposed = true;
        if (self.dispose_fn) |dispose_fn| dispose_fn(self);
    }
};

test "EditorInput defaults and matching" {
    const allocator = std.testing.allocator;
    var input = EditorInput.init(allocator, "test");
    defer input.deinit();

    try std.testing.expectEqualStrings("test", input.getName());
    try std.testing.expect(input.isReadonly());
    try std.testing.expect(input.hasCapability(EditorInputCapabilities.Readonly));
    try std.testing.expect(!input.matches(.{ .untyped = .{ .resource = null } }));

    var listener = ListenerCounter{};
    _ = try input.on_did_change_dirty.listen(&listener, ListenerCounter.onDirty);
    try input.fireDirty();
    try std.testing.expectEqual(@as(usize, 1), listener.count);
}

const ListenerCounter = struct {
    count: usize = 0,
    fn onDirty(_: void, self: *ListenerCounter) anyerror!void {
        self.count += 1;
    }
};
