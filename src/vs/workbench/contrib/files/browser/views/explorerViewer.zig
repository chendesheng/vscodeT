// Port of the `FilesFilter` portion of
// `src/vs/workbench/contrib/files/browser/views/explorerViewer.ts`.
//
// The browser filter owns a parsed `files.exclude` expression per workspace
// root, an ignore tree per root and the "folder leads to an exception" state
// used by `evaluateExcludeTreeEntry`. This port keeps that behavior and the
// upstream method names (`filter`, `isIgnored`, `isExcepted` through the
// parsed expression, `prepare` for ignore files).
//
// Terminal adaptations:
// - resources are canonical path strings, not `URI` objects;
// - ignore files are read synchronously through `std.Io.Dir`, so `prepare`
//   replaces the browser's asynchronous `processIgnoreFile` and file watcher;
// - the open-editor exception is an optional callback because the terminal
//   Explorer does not import the editor service;
// - `files.exclude` sibling clauses (`{ when: ... }`) are not ported, matching
//   the documented `glob.zig` limitation. Object values are treated as enabled
//   patterns, like the old TUI filter did.
//
// `ExplorerDelegate`, `ExplorerDataSource` and `FilesRenderer` from the same
// upstream file are not part of this port; the terminal tree owns row
// virtualization and painting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const glob = @import("../../../../../base/common/glob.zig");
const tree = @import("../../../../../base/browser/ui/tree/tree.zig");
const TreeVisibility = tree.TreeVisibility;
const explorer = @import("../../common/explorerModel.zig");
const ExplorerItem = explorer.ExplorerItem;
const ignore_file_module = @import("../../../../services/search/common/ignoreFile.zig");
const IgnoreFile = ignore_file_module.IgnoreFile;
const configuration_mod = @import("../../../../services/configuration/browser/configurationService.zig");
const ConfigurationService = configuration_mod.ConfigurationService;

const max_ignore_file_size: usize = 1024 * 1024;

/// Optional open-editor query. Upstream keeps excluded files visible while they
/// are open in an editor; the terminal host supplies that set through this
/// callback instead of importing the editor service.
pub const OpenEditorQuery = struct {
    context: *anyopaque,
    is_open: *const fn (context: *anyopaque, resource: []const u8) bool,
};

/// Emitted when a newly visited ignore file changes the filter. The terminal
/// Explorer does not watch ignore files yet, so the callback is optional.
pub const ChangeCallback = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque) void,
};

/// Applies the Explorer's `files.exclude` expression and, when enabled, one
/// ignore chain per resolved directory. Both settings are resource-scoped, so
/// each workspace root gets its own parsed root filter; the ignore-chain map is
/// keyed by the directory whose children are being resolved, mirroring
/// upstream's per-root ignore tree.
pub const FilesFilter = struct {
    allocator: Allocator,
    io: Io,
    configuration: *ConfigurationService,
    /// Owns every ignore file loaded while resolving directories.
    files: std.array_list.Managed(*IgnoreFile),
    /// Directory item -> ignore chain that applies to its children.
    chains: std.AutoHashMap(*ExplorerItem, ?*const IgnoreFile),
    /// Workspace root -> parsed `files.exclude` and ignore setting.
    roots: std.AutoHashMap(*ExplorerItem, *RootFilter),
    /// Excluded folders that are shown because an exception could match
    /// beneath them, mirroring upstream `foldersLeadingToExceptions`.
    folders_leading_to_exceptions: std.AutoHashMap(*ExplorerItem, void),
    open_editor: ?OpenEditorQuery = null,
    on_change: ?ChangeCallback = null,

    const RootFilter = struct {
        parsed: glob.ParsedExcludeExpression,
        exclude_git_ignore: bool,
    };

    pub fn init(
        allocator: Allocator,
        io: Io,
        configuration: *ConfigurationService,
    ) FilesFilter {
        return .{
            .allocator = allocator,
            .io = io,
            .configuration = configuration,
            .files = std.array_list.Managed(*IgnoreFile).init(allocator),
            .chains = std.AutoHashMap(*ExplorerItem, ?*const IgnoreFile).init(allocator),
            .roots = std.AutoHashMap(*ExplorerItem, *RootFilter).init(allocator),
            .folders_leading_to_exceptions = std.AutoHashMap(*ExplorerItem, void).init(allocator),
        };
    }

    pub fn deinit(self: *FilesFilter) void {
        var roots = self.roots.valueIterator();
        while (roots.next()) |root_filter| {
            root_filter.*.parsed.deinit();
            self.allocator.destroy(root_filter.*);
        }
        self.roots.deinit();
        for (self.files.items) |ignore_file| ignore_file.deinit();
        self.files.deinit();
        self.chains.deinit();
        self.folders_leading_to_exceptions.deinit();
    }

    pub fn setOpenEditorQuery(self: *FilesFilter, query: ?OpenEditorQuery) void {
        self.open_editor = query;
    }

    pub fn setOnChange(self: *FilesFilter, callback: ?ChangeCallback) void {
        self.on_change = callback;
    }

    /// Re-parses every root configuration after `files.exclude` or
    /// `explorer.excludeGitIgnore` changes. Existing ignore chains are kept.
    pub fn updateConfiguration(self: *FilesFilter) void {
        var roots = self.roots.valueIterator();
        while (roots.next()) |root_filter| {
            root_filter.*.parsed.deinit();
            self.allocator.destroy(root_filter.*);
        }
        self.roots.clearRetainingCapacity();
        self.folders_leading_to_exceptions.clearRetainingCapacity();
        if (self.on_change) |callback| callback.callback(callback.context);
    }

    /// Reads `<directory>/.gitignore` and `.ignore` on top of the enclosing
    /// directory's chain and records the chain for `directory`'s children.
    pub fn prepare(self: *FilesFilter, directory: *ExplorerItem) !void {
        const root_filter = try self.rootFilter(directory.root());
        if (!root_filter.exclude_git_ignore or self.chains.contains(directory)) return;

        var current: ?*const IgnoreFile = null;
        if (directory.parent) |parent| {
            if (self.chains.get(parent)) |chain| current = chain;
        }

        var changed = false;
        for (ignore_file_module.ignore_file_names) |name| {
            const path = try std.fs.path.join(self.allocator, &.{ directory.resource, name });
            defer self.allocator.free(path);
            const contents = Io.Dir.cwd().readFileAlloc(
                self.io,
                path,
                self.allocator,
                .limited(max_ignore_file_size),
            ) catch continue;
            defer self.allocator.free(contents);

            const ignore_file = try IgnoreFile.init(
                self.allocator,
                contents,
                directory.resource,
                current,
                false,
            );
            errdefer ignore_file.deinit();
            try self.files.append(ignore_file);
            current = ignore_file;
            changed = true;
        }

        try self.chains.put(directory, current);
        if (changed and self.on_change != null) {
            const callback = self.on_change.?;
            callback.callback(callback.context);
        }
    }

    /// Upstream `FilesFilter.filter`: updates `item.is_excluded`, returns
    /// whether the tree should show the item. `parent_visibility == .hidden`
    /// keeps the whole subtree hidden. An excluded folder is still visible when
    /// an exception could match beneath it, so the walker can reveal the
    /// exception.
    pub fn filter(
        self: *FilesFilter,
        item: *ExplorerItem,
        parent_visibility: TreeVisibility,
    ) bool {
        item.is_excluded = false;
        _ = self.folders_leading_to_exceptions.remove(item);

        if (parent_visibility == .hidden) {
            item.is_excluded = true;
            return false;
        }

        const root_filter = self.rootFilter(item.root()) catch return true;
        // Upstream always shows the ignore file itself so the user can edit
        // the file that hides its siblings. This port also reads `.ignore`.
        if (root_filter.exclude_git_ignore and isIgnoreFile(item.name)) return true;

        const parent = item.parent;
        const parent_excluded = if (parent) |value|
            value.is_excluded or self.folders_leading_to_exceptions.contains(value)
        else
            false;

        var hidden_context = HiddenContext{ .filter = self, .item = item };
        const result = glob.evaluateExcludeTreeEntry(&root_filter.parsed, .{
            .path = relativePath(item),
            .basename = item.name,
            .is_directory = item.is_directory,
            .is_parent_excluded = parent_excluded,
            .is_hidden = if (root_filter.exclude_git_ignore)
                .{ .context = &hidden_context, .callback = isHiddenCallback }
            else
                null,
        });

        if (!result.is_excluded) return true;

        if (result.is_visited) {
            self.folders_leading_to_exceptions.put(item, {}) catch {};
            return true;
        }

        item.is_excluded = true;
        // Upstream re-shows an excluded file (and its parents) while an editor
        // has it open.
        return self.isOpenEditor(item);
    }

    /// Upstream `isIgnored`: whether the resource is hidden by an ignore file
    /// and not re-included by an exclude exception or an exception-leading
    /// folder.
    pub fn isIgnored(self: *FilesFilter, item: *ExplorerItem) bool {
        if (!self.isGitIgnored(item)) return false;

        const root_filter = self.rootFilter(item.root()) catch return false;
        const relative = relativePath(item);
        if (root_filter.parsed.isExcepted(relative, item.name)) return false;
        if (item.is_directory and root_filter.parsed.couldExceptionMatchBeneath(relative)) return false;
        return true;
    }

    fn isGitIgnored(self: *FilesFilter, item: *ExplorerItem) bool {
        const chain = self.chainFor(item) orelse return false;
        return !ignore_file_module.isPathIncluded(chain, item.resource, item.is_directory);
    }

    /// Nearest prepared ignore chain for the item's parent. The terminal
    /// Explorer prepares a directory before resolving its children; this walk
    /// keeps nested items correct when only an ancestor was prepared.
    fn chainFor(self: *FilesFilter, item: *ExplorerItem) ?*const IgnoreFile {
        var parent = item.parent;
        while (parent) |value| {
            if (self.chains.get(value)) |chain| return chain;
            parent = value.parent;
        }
        return null;
    }

    fn isOpenEditor(self: *FilesFilter, item: *ExplorerItem) bool {
        const query = self.open_editor orelse return false;
        return query.is_open(query.context, item.resource);
    }

    fn rootFilter(self: *FilesFilter, root: *ExplorerItem) !*RootFilter {
        if (self.roots.get(root)) |root_filter| return root_filter;

        const entries = try buildExcludeEntries(self.allocator, self.configuration, root.resource);
        defer self.allocator.free(entries);

        const root_filter = try self.allocator.create(RootFilter);
        errdefer self.allocator.destroy(root_filter);
        root_filter.* = .{
            .parsed = try glob.ParsedExcludeExpression.init(self.allocator, entries, .{}),
            .exclude_git_ignore = getBoolForResource(
                self.configuration,
                "explorer.excludeGitIgnore",
                root.resource,
                true,
            ),
        };
        errdefer root_filter.parsed.deinit();
        try self.roots.put(root, root_filter);
        return root_filter;
    }
};

const HiddenContext = struct {
    filter: *FilesFilter,
    item: *ExplorerItem,
};

fn isHiddenCallback(context: *anyopaque) bool {
    const hidden: *HiddenContext = @ptrCast(@alignCast(context));
    return hidden.filter.isGitIgnored(hidden.item);
}

fn isIgnoreFile(name: []const u8) bool {
    return std.mem.eql(u8, name, ".gitignore") or std.mem.eql(u8, name, ".ignore");
}

fn getBoolForResource(
    configuration: *ConfigurationService,
    section: []const u8,
    resource: []const u8,
    default: bool,
) bool {
    const value = configuration.getValue(section, .{ .resource = resource }) orelse return default;
    return switch (value.*) {
        .bool => |inner| inner,
        else => default,
    };
}

/// The `files.exclude` object is an ordered expression: `true` enables a
/// pattern, `false` disables it, and a leading `!` marks an exception.
/// Object values are sibling clauses upstream; this port treats them as
/// enabled because `when` clauses are not supported by `glob.zig`.
fn buildExcludeEntries(
    allocator: Allocator,
    configuration: *ConfigurationService,
    resource: []const u8,
) ![]glob.ExcludeEntry {
    const value = configuration.getValue("files.exclude", .{ .resource = resource }) orelse
        return allocator.alloc(glob.ExcludeEntry, 0);

    var entries = std.array_list.Managed(glob.ExcludeEntry).init(allocator);
    errdefer entries.deinit();
    if (value.* == .object) {
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| {
            const enabled = switch (entry.value_ptr.*) {
                .bool => |inner| inner,
                .object => true,
                else => false,
            };
            try entries.append(.{
                .pattern = entry.key_ptr.*,
                .enabled = enabled,
            });
        }
    }
    return entries.toOwnedSlice();
}

fn relativePath(item: *ExplorerItem) []const u8 {
    const root = item.root();
    if (item == root) return "";
    const resource = item.resource;
    const root_resource = root.resource;
    if (std.mem.startsWith(u8, resource, root_resource)) {
        var index = root_resource.len;
        if (index < resource.len and (resource[index] == '/' or resource[index] == '\\')) index += 1;
        return resource[index..];
    }
    return resource;
}
