// Port of `src/vs/workbench/contrib/multiDiffEditor/common/multiDiffEditor.ts`.
// The event-backed preferences replace browser observables, retaining
// profile-scoped storage and window configuration semantics.
const std = @import("std");
const Allocator = std.mem.Allocator;
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const registry = @import("../../../../platform/configuration/common/configurationRegistry.zig");
const storage = @import("../../../../platform/storage/common/storage.zig");
const event = @import("../../../../base/common/event.zig");
const comparers = @import("../../../../base/common/comparers.zig");
const std_uri = @import("../../../../base/common/stdUri.zig");
const ResourceTree = @import("../../../../base/common/resourceTree.zig").ResourceTree;
pub const MultiDiffEditorVariant = @import("../../../../editor/common/multiDiffEditor.zig").MultiDiffEditorVariant;

pub const MULTI_DIFF_EDITOR_ID = "workbench.editor.multiDiffEditor";
pub const TOGGLE_MULTI_DIFF_EDITOR_FILE_LIST_COMMAND_ID = "multiDiffEditor.toggleFileList";
pub const multiDiffEditorExperimentalVariantSetting = "multiDiffEditor.experimental.variant";
pub const defaultMultiDiffEditorExperimentalVariant: MultiDiffEditorVariant = .noCards;
pub const multiDiffEditorExperimentalFileListSetting = "multiDiffEditor.experimental.fileList";
pub const multiDiffEditorFileListHiddenStorageKey = "multiDiffEditor.fileListHidden";
pub const multiDiffEditorFileListViewModeStorageKey = "multiDiffEditor.fileListViewMode";
pub const multiDiffEditorFileListPositionStorageKey = "multiDiffEditor.fileListPosition";
pub const FILE_LIST_WIDTH_STORAGE_KEY = "multiDiffEditor.fileListWidth";
pub const MultiDiffEditorFileListViewMode = enum { list, tree };
pub const MultiDiffEditorFileListPosition = enum { left, right };

pub const properties = [_]registry.PropertySchema{
    .{
        .key = multiDiffEditorExperimentalVariantSetting,
        .value_type = "string",
        .enum_values = &.{ "cards", "noCards" },
        .enum_descriptions = &.{ "Use the compact card-based variant.", "Use the compact variant without cards." },
        .default = .{ .string = "noCards" },
        .agents_window_default = .{ .string = "cards" },
        .scope = .WINDOW,
        .tags = &.{"experimental"},
        .experiment_mode = "auto",
    },
    .{
        .key = multiDiffEditorExperimentalFileListSetting,
        .value_type = "boolean",
        .default = .{ .bool = false },
        .agents_window_default = .{ .bool = true },
        .scope = .WINDOW,
        .tags = &.{"experimental"},
    },
};

pub fn getWorkbenchMultiDiffEditorVariant(value: ?[]const u8) MultiDiffEditorVariant {
    if (value) |name| if (std.mem.eql(u8, name, "cards")) return .cards;
    return defaultMultiDiffEditorExperimentalVariant;
}

pub fn isFileListHidden(service: storage.IStorageService) bool {
    return std.mem.eql(u8, service.get(multiDiffEditorFileListHiddenStorageKey, .profile, "false") orelse "false", "true");
}
pub fn toggleMultiDiffEditorFileList(service: storage.IStorageService) !void {
    if (isFileListHidden(service)) service.remove(multiDiffEditorFileListHiddenStorageKey, .profile) else try service.store(multiDiffEditorFileListHiddenStorageKey, .{ .boolean = true }, .profile, .user);
}
pub fn getFileListViewMode(service: storage.IStorageService) MultiDiffEditorFileListViewMode {
    return if (std.mem.eql(u8, service.get(multiDiffEditorFileListViewModeStorageKey, .profile, "list") orelse "list", "tree")) .tree else .list;
}
pub fn setMultiDiffEditorFileListViewMode(service: storage.IStorageService, mode: MultiDiffEditorFileListViewMode) !void {
    if (mode == .tree) try service.store(multiDiffEditorFileListViewModeStorageKey, .{ .string = "tree" }, .profile, .user) else service.remove(multiDiffEditorFileListViewModeStorageKey, .profile);
}
pub fn getFileListPosition(service: storage.IStorageService) MultiDiffEditorFileListPosition {
    return if (std.mem.eql(u8, service.get(multiDiffEditorFileListPositionStorageKey, .profile, "right") orelse "right", "left")) .left else .right;
}
pub fn setMultiDiffEditorFileListPosition(service: storage.IStorageService, position: MultiDiffEditorFileListPosition) !void {
    if (position == .left) try service.store(multiDiffEditorFileListPositionStorageKey, .{ .string = "left" }, .profile, .user) else service.remove(multiDiffEditorFileListPositionStorageKey, .profile);
}

pub const Preferences = struct {
    allocator: Allocator,
    configuration_service: configuration.IConfigurationService,
    storage_service: storage.IStorageService,
    /// Existing panes keep the widget type selected at their construction.
    available: bool,
    state: State,
    changed: event.Emitter(State),
    configuration_listener: ?event.SignalSubscription = null,
    storage_listener: ?event.SignalSubscription = null,

    pub const State = struct {
        variant: MultiDiffEditorVariant,
        enabled: bool,
        view_mode: MultiDiffEditorFileListViewMode,
        position: MultiDiffEditorFileListPosition,
    };
    pub fn create(allocator: Allocator, config: configuration.IConfigurationService, store: storage.IStorageService) !*Preferences {
        const self = try allocator.create(Preferences);
        const available = config.getBool(multiDiffEditorExperimentalFileListSetting, false);
        self.* = .{
            .allocator = allocator,
            .configuration_service = config,
            .storage_service = store,
            .available = available,
            .state = undefined,
            .changed = event.Emitter(State).init(allocator),
        };
        errdefer self.dispose();
        self.state = self.read();
        if (config.on_did_change_configuration) |changed| self.configuration_listener = try changed.listenDisposable(self, onConfiguration);
        if (store.on_did_change_value) |changed| self.storage_listener = try changed.listenDisposable(self, onStorage);
        return self;
    }
    pub fn dispose(self: *Preferences) void {
        if (self.configuration_listener) |listener| listener.dispose();
        if (self.storage_listener) |listener| listener.dispose();
        self.changed.deinit();
        self.allocator.destroy(self);
    }
    fn read(self: *Preferences) State {
        return .{
            .variant = getWorkbenchMultiDiffEditorVariant(self.configuration_service.getString(multiDiffEditorExperimentalVariantSetting)),
            .enabled = self.available and self.configuration_service.getBool(multiDiffEditorExperimentalFileListSetting, false) and !isFileListHidden(self.storage_service),
            .view_mode = getFileListViewMode(self.storage_service),
            .position = getFileListPosition(self.storage_service),
        };
    }
    fn refresh(self: *Preferences) !void {
        const next = self.read();
        if (std.meta.eql(self.state, next)) return;
        self.state = next;
        try self.changed.fire(next);
    }
    fn onConfiguration(change: configuration.Change, self: *Preferences) !void {
        if (configuration.affectsConfiguration(change, multiDiffEditorExperimentalVariantSetting) or configuration.affectsConfiguration(change, multiDiffEditorExperimentalFileListSetting)) try self.refresh();
    }
    fn onStorage(change: storage.IStorageValueChangeEvent, self: *Preferences) !void {
        if (change.scope != .profile) return;
        if (std.mem.eql(u8, change.key, multiDiffEditorFileListHiddenStorageKey) or std.mem.eql(u8, change.key, multiDiffEditorFileListViewModeStorageKey) or std.mem.eql(u8, change.key, multiDiffEditorFileListPositionStorageKey)) try self.refresh();
    }
};

/// Stable order of the changed files, including multiple resources at the
/// same path and a file that is also a parent of another resource.
pub fn sortMultiDiffEditorFileListItems(comptime T: type, allocator: Allocator, items: []const T, getUri: *const fn (T) std.Uri, view_mode: MultiDiffEditorFileListViewMode) ![]T {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const result = try allocator.alloc(T, items.len);
    errdefer allocator.free(result);
    if (view_mode == .list) {
        const Entry = struct { item: T, path: []const u8, index: usize };
        const entries = try a.alloc(Entry, items.len);
        for (items, entries, 0..) |item, *entry, i| entry.* = .{ .item = item, .path = try std_uri.path(getUri(item), a), .index = i };
        std.mem.sort(Entry, entries, {}, struct {
            fn less(_: void, left: Entry, right: Entry) bool {
                const order = comparers.comparePaths(left.path, right.path);
                return order < 0 or (order == 0 and left.index < right.index);
            }
        }.less);
        for (entries, result) |entry, *dst| dst.* = entry.item;
    } else {
        const Tree = ResourceTree(std.ArrayList(T), void);
        var tree = try Tree.init(a, {}, "/");
        defer tree.deinit();
        for (items) |item| {
            const path = try std_uri.path(getUri(item), a);
            if (tree.getNode(path)) |node| {
                if (node.element) |*bucket| {
                    try bucket.append(a, item);
                    continue;
                }
            }
            var bucket: std.ArrayList(T) = .empty;
            try bucket.append(a, item);
            _ = try tree.add(path, bucket);
        }
        const Collector = struct {
            fn less(_: void, left: *Tree.NodeType, right: *Tree.NodeType) bool {
                const left_folder = left.childrenCount() > 0;
                const right_folder = right.childrenCount() > 0;
                if (left_folder != right_folder) return left_folder;
                return comparers.compareFileNames(left.name, right.name) < 0;
            }
            fn collect(node: *Tree.NodeType, out: []T, offset: *usize) void {
                std.mem.sort(*Tree.NodeType, node.children.items, {}, less);
                for (node.children.items) |child| {
                    if (child.element) |bucket| {
                        @memcpy(out[offset.* .. offset.* + bucket.items.len], bucket.items);
                        offset.* += bucket.items.len;
                    }
                    collect(child, out, offset);
                }
            }
        };
        var offset: usize = 0;
        Collector.collect(tree.root, result, &offset);
        std.debug.assert(offset == result.len);
    }
    return result;
}
