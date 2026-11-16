// Port of `src/vs/workbench/contrib/files/common/explorerModel.ts`.
//
// Terminal adaptation: upstream `ExplorerItem` uses `URI`, `IFileService` and
// configuration services. The TUI has no file service yet, so resources are
// canonical path strings, children are resolved directly with `std.Io.Dir`,
// and the sort order is a small enum. The tree/merge/rename/move/find
// behavior and names follow upstream.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const workspace_context = @import("../../../services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;

pub const SortOrder = enum {
    Default,
    Mixed,
    FilesFirst,
    Type,
    Modified,
};

pub const ExplorerItem = struct {
    allocator: Allocator,
    resource: []u8,
    name: []u8,
    parent: ?*ExplorerItem,
    is_directory: bool,
    is_symbolic_link: bool,
    is_directory_resolved: bool = false,
    mtime: i64 = 0,
    unknown: bool = false,
    /// Set by `FilesFilter.filter` when the item is hidden by an exclude
    /// pattern or ignore file. Explorer views use it to keep a hidden parent
    /// chain hidden without re-evaluating every ancestor.
    is_excluded: bool = false,
    children: std.array_list.Managed(*ExplorerItem),

    pub fn create(
        allocator: Allocator,
        resource: []const u8,
        name: []const u8,
        parent: ?*ExplorerItem,
        is_directory: bool,
    ) !*ExplorerItem {
        const item = try allocator.create(ExplorerItem);
        errdefer allocator.destroy(item);
        const resource_copy = try allocator.dupe(u8, resource);
        errdefer allocator.free(resource_copy);
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        item.* = .{
            .allocator = allocator,
            .resource = resource_copy,
            .name = name_copy,
            .parent = parent,
            .is_directory = is_directory,
            .is_symbolic_link = false,
            .children = std.array_list.Managed(*ExplorerItem).init(allocator),
        };
        return item;
    }

    pub fn destroy(self: *ExplorerItem) void {
        for (self.children.items) |child| child.destroy();
        self.children.deinit();
        const allocator = self.allocator;
        allocator.free(self.resource);
        allocator.free(self.name);
        allocator.destroy(self);
    }

    pub fn root(self: *ExplorerItem) *ExplorerItem {
        var item = self;
        while (item.parent) |parent| item = parent;
        return item;
    }

    pub fn getChild(self: *const ExplorerItem, name: []const u8) ?*ExplorerItem {
        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.name, name)) return child;
        }
        return null;
    }

    pub fn addChild(self: *ExplorerItem, child: *ExplorerItem) !void {
        if (child.parent) |old_parent| old_parent.removeChild(child);
        child.parent = self;
        try child.updateResourceRecursive();
        try self.children.append(child);
    }

    pub fn removeChild(self: *ExplorerItem, child: *ExplorerItem) void {
        for (self.children.items, 0..) |candidate, index| {
            if (candidate == child) {
                _ = self.children.orderedRemove(index);
                child.parent = null;
                return;
            }
        }
    }

    pub fn move(self: *ExplorerItem, new_parent: *ExplorerItem) !void {
        try new_parent.addChild(self);
    }

    pub fn rename(self: *ExplorerItem, new_name: []const u8) !void {
        const parent = self.parent;
        if (parent) |value| value.removeChild(self);

        const name_copy = try self.allocator.dupe(u8, new_name);
        self.allocator.free(self.name);
        self.name = name_copy;

        if (parent) |value| {
            try value.addChild(self);
        } else {
            try self.updateResourceRecursive();
        }
    }

    fn updateResourceRecursive(self: *ExplorerItem) !void {
        var new_resource: []u8 = undefined;
        if (self.parent) |parent| {
            new_resource = try std.fs.path.join(self.allocator, &.{ parent.resource, self.name });
        } else {
            new_resource = try self.allocator.dupe(u8, self.name);
        }
        self.allocator.free(self.resource);
        self.resource = new_resource;

        for (self.children.items) |child| try child.updateResourceRecursive();
    }

    /// Resolves the directory's direct children from disk. This mirrors
    /// `fetchChildren`, including the resolved flag and sorting.
    pub fn fetchChildren(self: *ExplorerItem, io: Io, sort_order: SortOrder) !void {
        if (!self.is_directory or self.is_directory_resolved) return;

        var dir = Io.Dir.cwd().openDir(io, self.resource, .{ .iterate = true }) catch {
            self.is_directory_resolved = true;
            return;
        };
        defer dir.close(io);

        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            const path = try std.fs.path.join(self.allocator, &.{ self.resource, entry.name });
            defer self.allocator.free(path);
            const child = try ExplorerItem.create(
                self.allocator,
                path,
                entry.name,
                self,
                entry.kind == .directory,
            );
            try self.children.append(child);
        }

        self.sortChildren(sort_order);
        self.is_directory_resolved = true;
    }

    pub fn sortChildren(self: *ExplorerItem, sort_order: SortOrder) void {
        std.mem.sort(*ExplorerItem, self.children.items, sort_order, lessThan);
    }

    fn lessThan(order: SortOrder, a: *ExplorerItem, b: *ExplorerItem) bool {
        if (order != .Mixed and a.is_directory != b.is_directory) {
            return a.is_directory;
        }
        if (order == .Type and !a.is_directory and !b.is_directory) {
            const a_extension = std.fs.path.extension(a.name);
            const b_extension = std.fs.path.extension(b.name);
            if (!std.ascii.eqlIgnoreCase(a_extension, b_extension)) {
                return std.ascii.lessThanIgnoreCase(a_extension, b_extension);
            }
        }
        return std.ascii.lessThanIgnoreCase(a.name, b.name);
    }

    pub fn find(self: *ExplorerItem, resource: []const u8) ?*ExplorerItem {
        if (std.mem.eql(u8, self.resource, resource)) return self;
        for (self.children.items) |child| {
            if (child.find(resource)) |found| return found;
        }
        return null;
    }

    pub fn forgetChildren(self: *ExplorerItem) void {
        for (self.children.items) |child| child.destroy();
        self.children.clearRetainingCapacity();
        self.is_directory_resolved = false;
    }
};

pub const ExplorerModel = struct {
    allocator: Allocator,
    io: Io,
    context: *WorkspaceContextService,
    roots: std.array_list.Managed(*ExplorerItem),

    pub fn init(allocator: Allocator, io: Io, context: *WorkspaceContextService) !*ExplorerModel {
        const self = try allocator.create(ExplorerModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .context = context,
            .roots = std.array_list.Managed(*ExplorerItem).init(allocator),
        };

        for (context.getWorkspace().folders.items) |folder| {
            try self.roots.append(try ExplorerItem.create(
                allocator,
                folder.resource,
                folder.name,
                null,
                true,
            ));
        }
        return self;
    }

    pub fn deinit(self: *ExplorerModel) void {
        for (self.roots.items) |root| root.destroy();
        self.roots.deinit();
        self.allocator.destroy(self);
    }

    pub fn findAll(self: *ExplorerModel, allocator: Allocator, resource: []const u8) ![]*ExplorerItem {
        var result = std.array_list.Managed(*ExplorerItem).init(allocator);
        errdefer result.deinit();
        for (self.roots.items) |root| {
            if (root.find(resource)) |item| try result.append(item);
        }
        return result.toOwnedSlice();
    }

    pub fn findClosest(self: *ExplorerModel, resource: []const u8) ?*ExplorerItem {
        const folder = self.context.getWorkspaceFolder(resource) orelse return null;
        for (self.roots.items) |root| {
            if (std.mem.eql(u8, root.resource, folder.resource)) {
                return root.find(resource);
            }
        }
        return null;
    }
};
