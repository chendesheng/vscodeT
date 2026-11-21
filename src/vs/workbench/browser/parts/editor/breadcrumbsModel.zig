// Port of `src/vs/workbench/browser/parts/editor/breadcrumbsModel.ts`.
//
// The browser model resolves a URI to file-path elements through the workspace
// context, label and URI-identity services, and appends outline elements from
// `IOutlineService`. The terminal port works on path strings: resources are
// canonical paths, and the workspace folder supplies the root label and the
// relative/absolute decision.
//
// Terminal adaptations:
// - `ILabelService` and `IUriIdentityService` are not ported. Home-relative
//   paths use a single `~` root segment instead of upstream's per-component
//   home labels; workspace-relative and absolute paths are otherwise used.
// - The outline is created synchronously by `OutlineService`; provider updates
//   arrive through `IOutline.onDidChange`.
// - The model emits `on_did_update` after the element list or workspace root
//   changes, matching upstream's `onDidUpdate`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const files = @import("../../../../platform/files/common/files.zig");
const FileKind = files.FileKind;
const workspace_mod = @import("../../../../platform/workspace/common/workspace.zig");
const WorkbenchState = workspace_mod.WorkbenchState;
const WorkspaceContextService = @import("../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const outline_mod = @import("../../../services/outline/browser/outline.zig");
const outline_service_mod = @import("../../../services/outline/browser/outlineService.zig");
const OutlineService = outline_service_mod.OutlineService;
const OutlineEditor = outline_mod.OutlineEditor;
const OutlineTarget = outline_mod.OutlineTarget;
const OutlineChangeEvent = outline_mod.OutlineChangeEvent;
const IOutline = outline_mod.IOutline;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const breadcrumbs = @import("breadcrumbs.zig");
const Settings = breadcrumbs.Settings;
const PathMode = breadcrumbs.PathMode;

/// One path segment. Paths and labels are owned by the model.
pub const FileElement = struct {
    path: []u8,
    kind: FileKind,
    label: ?[]u8 = null,

    pub fn equals(a: FileElement, b: FileElement) bool {
        const labels_equal = if (a.label) |left| blk: {
            const right = b.label orelse break :blk false;
            break :blk std.mem.eql(u8, left, right);
        } else b.label == null;
        return a.kind == b.kind and labels_equal and std.mem.eql(u8, a.path, b.path);
    }

    fn deinit(self: *FileElement, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.label) |label| allocator.free(label);
    }
};

/// Upstream `OutlineElement2`: the symbol element plus the outline that owns
/// it. Labels are borrowed from the outline and stay valid until it is
/// disposed.
pub const OutlineElement2 = struct {
    element: *anyopaque,
    outline: *IOutline,
    label: []const u8,
    symbol_kind: ?u32 = null,
    placeholder: bool = false,
};

pub const Element = union(enum) {
    /// Points into `BreadcrumbsModel.file_info.path`.
    file: *const FileElement,
    outline: OutlineElement2,
    placeholder,
};

const FileInfo = struct {
    path: std.array_list.Managed(FileElement),
    is_relative: bool = false,
};

pub const BreadcrumbsModel = struct {
    allocator: Allocator,
    resource: []const u8,
    workspace: *WorkspaceContextService,
    settings: Settings,
    outline_service: ?*OutlineService,
    editor: ?OutlineEditor,
    home: ?[]const u8,
    file_info: FileInfo,
    elements: std.array_list.Managed(Element),
    outline: ?*IOutline = null,
    outline_listener: ?Emitter(OutlineChangeEvent).ListenerId = null,
    service_listener: ?Emitter(void).ListenerId = null,
    on_did_update: Emitter(void),

    pub fn init(
        allocator: Allocator,
        resource: []const u8,
        workspace: *WorkspaceContextService,
        settings: Settings,
        outline_service: ?*OutlineService,
        editor: ?OutlineEditor,
        home: ?[]const u8,
    ) !*BreadcrumbsModel {
        const self = try allocator.create(BreadcrumbsModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .resource = resource,
            .workspace = workspace,
            .settings = settings,
            .outline_service = outline_service,
            .editor = editor,
            .home = home,
            .file_info = .{ .path = std.array_list.Managed(FileElement).init(allocator) },
            .elements = std.array_list.Managed(Element).init(allocator),
            .on_did_update = Emitter(void).init(allocator),
        };
        errdefer self.deinitSlices();

        try self.initFilePathInfo();
        self.bindToEditor();
        try self.rebuildElements();
        return self;
    }

    fn deinitSlices(self: *BreadcrumbsModel) void {
        self.unbind();
        for (self.file_info.path.items) |*element| element.deinit(self.allocator);
        self.file_info.path.deinit();
        self.elements.deinit();
        self.on_did_update.deinit();
    }

    pub fn deinit(self: *BreadcrumbsModel) void {
        self.deinitSlices();
        self.allocator.destroy(self);
    }

    pub fn getElements(self: *const BreadcrumbsModel) []const Element {
        return self.elements.items;
    }

    pub fn isRelative(self: *const BreadcrumbsModel) bool {
        return self.file_info.is_relative;
    }

    /// Re-resolves the path (workspace folders changed) and rebuilds the
    /// element list.
    pub fn refresh(self: *BreadcrumbsModel) !void {
        for (self.file_info.path.items) |*element| element.deinit(self.allocator);
        self.file_info.path.clearRetainingCapacity();
        try self.initFilePathInfo();
        try self.rebuildElements();
        try self.on_did_update.fire({});
    }

    pub fn setSettings(self: *BreadcrumbsModel, settings: Settings) !void {
        self.settings = settings;
        try self.rebuildElements();
        try self.on_did_update.fire({});
    }

    /// Rebinds to the current outline service state, like upstream
    /// `_bindToEditor` after `onDidChange`. The service listener stays in place
    /// so this never appends to the emitter that is currently firing.
    pub fn rebindOutline(self: *BreadcrumbsModel) !void {
        self.disposeOutline();
        self.bindOutline();
        try self.rebuildElements();
        try self.on_did_update.fire({});
    }

    fn initFilePathInfo(self: *BreadcrumbsModel) !void {
        const resource = self.resource;
        if (resource.len == 0) return;

        const folder = self.workspace.getWorkspaceFolder(resource);
        const under_home = self.home != null and isUnderRoot(resource, self.home.?);
        self.file_info.is_relative = folder != null or under_home;

        // Collect from the file upwards, then prepend so the list is ordered
        // from the workspace root (or the top-most outside folder) to the file.
        var current: []const u8 = resource;
        var first = true;
        while (!isRoot(current)) {
            if (folder) |workspace_folder| {
                if (samePath(current, workspace_folder.resource)) break;
            }
            if (under_home and samePath(current, self.home.?)) break;
            const element = FileElement{
                .path = try self.allocator.dupe(u8, current),
                .kind = if (first) .FILE else .FOLDER,
            };
            errdefer self.allocator.free(element.path);
            try self.file_info.path.insert(0, element);
            first = false;

            const parent = dirnameAny(current);
            if (parent.len == current.len) break;
            current = parent;
        }

        if (folder) |workspace_folder| {
            const state = self.workspace.getWorkbenchState();
            const folder_count = self.workspace.getWorkspace().folders.items.len;
            if (includeWorkspaceRoot(state, folder_count, workspace_folder.resource, resource)) {
                const label = try self.allocator.dupe(u8, workspace_folder.name);
                errdefer self.allocator.free(label);
                try self.file_info.path.insert(0, .{
                    .path = try self.allocator.dupe(u8, workspace_folder.resource),
                    .kind = .ROOT_FOLDER,
                    .label = label,
                });
            }
        } else if (under_home) {
            // Upstream prepends the home path labels; the terminal uses the
            // conventional `~` root segment instead of every home component.
            const label = try self.allocator.dupe(u8, "~");
            errdefer self.allocator.free(label);
            try self.file_info.path.insert(0, .{
                .path = try self.allocator.dupe(u8, self.home.?),
                .kind = .ROOT_FOLDER,
                .label = label,
            });
        }
    }

    fn rebuildElements(self: *BreadcrumbsModel) !void {
        self.elements.clearRetainingCapacity();

        switch (self.settings.file_path) {
            .on => for (self.file_info.path.items) |*element| {
                try self.elements.append(.{ .file = element });
            },
            .last => if (self.file_info.path.items.len > 0) {
                try self.elements.append(.{ .file = &self.file_info.path.items[self.file_info.path.items.len - 1] });
            },
            .off => {},
        }

        if (self.settings.symbol_path == .off) return;
        const outline = self.outline orelse return;
        const data_source = outline.config.breadcrumbs_data_source;
        const symbols = data_source.get_breadcrumb_elements(data_source.context);
        if (symbols.len == 0) {
            if (!outline.is_empty) try self.elements.append(.placeholder);
            return;
        }
        const start: usize = if (self.settings.symbol_path == .last) symbols.len - 1 else 0;
        for (symbols[start..]) |symbol| {
            try self.elements.append(.{ .outline = .{
                .element = symbol.element,
                .outline = outline,
                .label = symbol.label,
                .symbol_kind = symbol.symbol_kind,
            } });
        }
    }

    fn bindToEditor(self: *BreadcrumbsModel) void {
        const service = self.outline_service orelse return;
        self.bindOutline();
        self.service_listener = service.on_did_change.listen(self, onServiceChanged) catch null;
    }

    fn bindOutline(self: *BreadcrumbsModel) void {
        const service = self.outline_service orelse return;
        const editor = self.editor orelse return;
        self.outline = service.createOutline(editor, .Breadcrumbs) catch null;
        if (self.outline) |outline| {
            if (outline.on_did_change) |emitter| {
                self.outline_listener = emitter.listen(self, onOutlineChanged) catch null;
            }
        }
    }

    fn disposeOutline(self: *BreadcrumbsModel) void {
        if (self.outline) |outline| {
            if (outline.on_did_change) |emitter| {
                if (self.outline_listener) |id| emitter.unlisten(id);
            }
            self.outline_listener = null;
            outline.dispose();
            self.outline = null;
        }
    }

    fn unbind(self: *BreadcrumbsModel) void {
        self.disposeOutline();
        if (self.outline_service) |service| {
            if (self.service_listener) |id| service.on_did_change.unlisten(id);
            self.service_listener = null;
        }
    }

    fn onOutlineChanged(_: OutlineChangeEvent, self: *BreadcrumbsModel) anyerror!void {
        try self.rebuildElements();
        try self.on_did_update.fire({});
    }

    fn onServiceChanged(_: void, self: *BreadcrumbsModel) anyerror!void {
        try self.rebindOutline();
    }
};

/// Upstream `_initFilePathInfo`: a root folder segment is shown only in a
/// multi-root workspace, or for the workspace folder that is the resource
/// itself. A single-folder `.FOLDER` workspace keeps the folder out of the
/// breadcrumb path.
fn isUnderRoot(path: []const u8, root: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, root, "/\\");
    if (trimmed.len == 0 or path.len <= trimmed.len) return false;
    if (!std.mem.startsWith(u8, path, trimmed)) return false;
    return path[trimmed.len] == '/' or path[trimmed.len] == '\\';
}

pub fn includeWorkspaceRoot(
    state: WorkbenchState,
    folder_count: usize,
    folder_resource: []const u8,
    resource: []const u8,
) bool {
    // The local workspace service reports `.FOLDER` for a folder-only
    // workspace, so multiple folders are still the authoritative multi-root
    // signal (a real multi-root workspace always carries a configuration).
    return folder_count > 1 or
        (state == .WORKSPACE and samePath(folder_resource, resource));
}

fn isSeparator(character: u8) bool {
    return character == '/' or character == '\\';
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and isSeparator(path[end - 1])) end -= 1;
    return path[0..end];
}

fn samePath(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, trimTrailingSeparators(a), trimTrailingSeparators(b));
}

fn isRoot(path: []const u8) bool {
    if (path.len == 1 and isSeparator(path[0])) return true;
    if (path.len == 3 and path[1] == ':' and isSeparator(path[2])) return true;
    return false;
}

/// Platform-independent dirname for the path strings stored in the workspace
/// service. Returns the input unchanged at a root or when no separator exists.
fn dirnameAny(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    var end = path.len;
    while (end > 0 and isSeparator(path[end - 1])) end -= 1;
    var index = end;
    while (index > 0) : (index -= 1) {
        if (isSeparator(path[index - 1])) {
            var parent_end = index - 1;
            if (parent_end == 0) return path[0..1];
            // Keep a Windows drive root ("C:/").
            if (parent_end == 2 and path[1] == ':') return path[0..3];
            while (parent_end > 0 and isSeparator(path[parent_end - 1])) parent_end -= 1;
            if (parent_end == 0) return path[0..1];
            return path[0..parent_end];
        }
    }
    return path;
}

test "breadcrumb model: workspace root only in a workspace state" {
    try std.testing.expect(includeWorkspaceRoot(.WORKSPACE, 2, "/w/a", "/w/a/f.ts"));
    try std.testing.expect(includeWorkspaceRoot(.WORKSPACE, 1, "/w/a", "/w/a"));
    try std.testing.expect(!includeWorkspaceRoot(.WORKSPACE, 1, "/w/a", "/w/a/f.ts"));
    try std.testing.expect(includeWorkspaceRoot(.FOLDER, 2, "/w/a", "/w/a/f.ts"));
    try std.testing.expect(!includeWorkspaceRoot(.FOLDER, 1, "/w/a", "/w/a/f.ts"));
    try std.testing.expect(!includeWorkspaceRoot(.EMPTY, 0, "/w/a", "/w/a/f.ts"));
}
