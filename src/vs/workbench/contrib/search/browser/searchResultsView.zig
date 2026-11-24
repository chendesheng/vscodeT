// Port of the portable view behavior in
// `src/vs/workbench/contrib/search/browser/searchResultsView.ts`.
//
// Terminal adaptations:
// - there is no DOM template, action bar or badge widget; `rowData` returns the
//   label/count/preview fields the terminal paints;
// - compressed folder chains are not rendered, so `renderCompressedElements`
//   has no equivalent;
// - AI/notebook rows are omitted with the rest of those subsystems.
//
// The data source and ordering are the upstream ones for text results: a single
// workspace folder is transparent, list mode flattens files, tree mode nests
// folders, and each level is sorted with `searchCompare.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tree = @import("searchTreeModel/searchTreeCommon.zig");
const Node = tree.Node;
const SearchResult = tree.SearchResult;
const TextSearchHeading = tree.TextSearchHeading;
const FolderMatch = tree.FolderMatch;
const FileMatch = tree.FileMatch;
const Match = tree.Match;
const SearchModel = @import("searchTreeModel/searchModel.zig").SearchModel;
const compare = @import("searchCompare.zig");
const search = @import("../../../services/search/common/search.zig");
const ViewMode = search.ViewMode;
const SearchSortOrder = search.SearchSortOrder;

pub const Template = enum { text_result_match, folder_match, file_match, match };

pub const SearchDelegate = struct {
    pub fn getHeight(_: Template) usize {
        return 1;
    }

    pub fn getTemplateId(node: Node) Template {
        return switch (node) {
            .heading => .text_result_match,
            .folder => .folder_match,
            .file => .file_match,
            .match => .match,
        };
    }
};

pub const ViewState = struct {
    mode: ViewMode = .list,
    sort_order: SearchSortOrder = .default,
    show_line_numbers: bool = false,
};

/// One flattened, visible row. `depth` is the tree depth upstream's renderer
/// receives from `ITreeNode`; the terminal adapter uses it for indentation.
pub const VisibleRow = struct {
    node: Node,
    depth: usize,
};

/// Collapse state supplied by the view. `on_visit` lets the adapter apply
/// `search.collapseResults` before the row is checked.
pub const CollapseState = struct {
    context: *anyopaque,
    is_collapsed: *const fn (context: *anyopaque, node: Node) bool,
    on_visit: ?*const fn (context: *anyopaque, node: Node) void = null,
};

/// Terminal cell mapping for the tree indent upstream applies through CSS.
/// The twisty occupies the row's first cell, so depth zero starts at the left
/// edge; each tree level adds two cells.
pub fn indentCells(depth: usize) usize {
    return depth * 2;
}

/// Match rows sit one cell inside their file row, matching the upstream
/// renderer's line-match padding.
pub fn matchIndentCells(depth: usize) usize {
    return indentCells(depth) + 1;
}

pub const RowData = struct {
    template: Template,
    label: []const u8,
    description: []const u8 = "",
    count: usize = 0,
    collapsible: bool = false,
    line_number: usize = 0,
    extra_lines: usize = 0,
    before: []const u8 = "",
    before_truncated: bool = false,
    inside: []const u8 = "",
    after: []const u8 = "",

    pub fn lineLabel(self: RowData, buffer: []u8) []const u8 {
        if (self.line_number > 0 and self.extra_lines > 0) {
            return std.fmt.bufPrint(buffer, "{d}:+{d}", .{ self.line_number, self.extra_lines }) catch "";
        }
        if (self.line_number > 0) return std.fmt.bufPrint(buffer, "{d}:", .{self.line_number}) catch "";
        if (self.extra_lines > 0) return std.fmt.bufPrint(buffer, "+{d}", .{self.extra_lines}) catch "";
        return "";
    }
};

/// Port of upstream `SearchViewDataSource`. Slices returned by the `get*`
/// functions are owned by the caller.
pub const SearchViewDataSource = struct {
    result: *SearchResult,
    state: ViewState,

    pub fn init(result: *SearchResult, state: ViewState) SearchViewDataSource {
        return .{ .result = result, .state = state };
    }

    pub fn getRootChildren(self: *const SearchViewDataSource, allocator: Allocator) ![]Node {
        if (self.result.isEmpty()) return try allocator.alloc(Node, 0);
        return self.createTextSearchResultIterator(allocator, self.result.heading);
    }

    pub fn getChildren(self: *const SearchViewDataSource, allocator: Allocator, element: Node) ![]Node {
        return switch (element) {
            .heading => |heading| self.createTextSearchResultIterator(allocator, heading),
            .folder => |folder| self.createFolderIterator(allocator, folder),
            .file => |file| self.createFileIterator(allocator, file),
            .match => try allocator.alloc(Node, 0),
        };
    }

    pub fn hasChildren(_: *const SearchViewDataSource, element: Node) bool {
        return switch (element) {
            .match => false,
            .heading => true,
            .folder => |folder| folder.recursiveMatchCount() > 0,
            .file => |file| file.hasChildren(),
        };
    }

    pub fn getParent(_: *const SearchViewDataSource, element: Node) ?Node {
        return switch (element) {
            .heading => null,
            .folder => |folder| if (folder.parent_folder) |parent|
                Node{ .folder = parent }
            else
                Node{ .heading = folder.heading },
            .file => |file| Node{ .folder = file.parent_folder },
            .match => |match| Node{ .file = match.parent_file },
        };
    }

    /// Flattens the data source into visible rows in upstream tree order.
    /// Collapsed nodes still appear, but their children are skipped.
    pub fn visibleRows(
        self: *const SearchViewDataSource,
        allocator: Allocator,
        collapse: CollapseState,
    ) ![]VisibleRow {
        var rows = std.array_list.Managed(VisibleRow).init(allocator);
        errdefer rows.deinit();
        const roots = try self.getRootChildren(allocator);
        defer allocator.free(roots);
        try self.appendVisible(allocator, roots, 0, collapse, &rows);
        return try rows.toOwnedSlice();
    }

    fn appendVisible(
        self: *const SearchViewDataSource,
        allocator: Allocator,
        nodes: []const Node,
        depth: usize,
        collapse: CollapseState,
        rows: *std.array_list.Managed(VisibleRow),
    ) !void {
        for (nodes) |node| {
            if (collapse.on_visit) |visit| visit(collapse.context, node);
            try rows.append(.{ .node = node, .depth = depth });
            if (node == .match) continue;
            if (collapse.is_collapsed(collapse.context, node)) continue;
            {
                const children = try self.getChildren(allocator, node);
                defer allocator.free(children);
                try self.appendVisible(allocator, children, depth + 1, collapse, rows);
            }
        }
    }

    fn createTextSearchResultIterator(
        self: *const SearchViewDataSource,
        allocator: Allocator,
        heading: *TextSearchHeading,
    ) ![]Node {
        const folders = try heading.folderMatches(allocator);
        defer allocator.free(folders);
        std.sort.heap(*FolderMatch, folders, self.state.sort_order, folderLessThan);
        if (folders.len == 1) {
            return self.createFolderIterator(allocator, folders[0]);
        }
        const result = try allocator.alloc(Node, folders.len);
        for (folders, 0..) |folder, index| result[index] = .{ .folder = folder };
        return result;
    }

    fn createFolderIterator(
        self: *const SearchViewDataSource,
        allocator: Allocator,
        folder: *FolderMatch,
    ) ![]Node {
        if (self.state.mode == .tree) {
            const matches = try folder.matches(allocator);
            std.sort.heap(Node, matches, self.state.sort_order, nodeLessThan);
            return matches;
        }

        const files = try folder.allDownstreamFiles(allocator);
        defer allocator.free(files);
        std.sort.heap(*FileMatch, files, self.state.sort_order, fileLessThan);
        const result = try allocator.alloc(Node, files.len);
        for (files, 0..) |file, index| result[index] = .{ .file = file };
        return result;
    }

    fn createFileIterator(
        self: *const SearchViewDataSource,
        allocator: Allocator,
        file: *FileMatch,
    ) ![]Node {
        const matches = file.matches();
        const sorted = try allocator.dupe(*Match, matches);
        defer allocator.free(sorted);
        std.sort.heap(*Match, sorted, self.state.sort_order, matchLessThan);
        const result = try allocator.alloc(Node, sorted.len);
        for (sorted, 0..) |match, index| result[index] = .{ .match = match };
        return result;
    }
};

fn folderLessThan(sort_order: SearchSortOrder, a: *FolderMatch, b: *FolderMatch) bool {
    return compare.searchMatchComparer(.{ .folder = a }, .{ .folder = b }, sort_order) < 0;
}

fn fileLessThan(sort_order: SearchSortOrder, a: *FileMatch, b: *FileMatch) bool {
    return compare.searchMatchComparer(.{ .file = a }, .{ .file = b }, sort_order) < 0;
}

fn matchLessThan(sort_order: SearchSortOrder, a: *Match, b: *Match) bool {
    return compare.searchMatchComparer(.{ .match = a }, .{ .match = b }, sort_order) < 0;
}

fn nodeLessThan(sort_order: SearchSortOrder, a: Node, b: Node) bool {
    return compare.searchMatchComparer(a, b, sort_order) < 0;
}

/// Port of the label-producing halves of the four upstream renderers.
pub fn rowData(node: Node, state: ViewState) RowData {
    return switch (node) {
        .heading => |heading| .{
            .template = .text_result_match,
            .label = heading.name(),
            .count = heading.count(),
            .collapsible = true,
        },
        .folder => |folder| .{
            .template = .folder_match,
            .label = folder.name,
            .count = folder.recursiveMatchCount(),
            .collapsible = folder.recursiveMatchCount() > 0,
        },
        .file => |file| .{
            .template = .file_match,
            .label = file.name,
            .description = if (state.mode == .list or file.parent_folder.is_other) std.fs.path.dirname(relativePath(file)) orelse "" else "",
            .count = file.count(),
            .collapsible = file.hasChildren(),
        },
        .match => |match| blk: {
            const preview = match.preview();
            const range = match.range();
            const extra_lines = if (range.endLineNumber > range.startLineNumber)
                range.endLineNumber - range.startLineNumber
            else
                0;
            break :blk .{
                .template = .match,
                .label = preview.inside,
                .before = preview.before,
                .before_truncated = preview.before_truncated,
                .inside = preview.inside,
                .after = preview.after,
                .line_number = if (state.show_line_numbers) range.startLineNumber else 0,
                .extra_lines = extra_lines,
            };
        },
    };
}

/// Relative path used by the list-mode file row.
pub fn relativePath(file: *const FileMatch) []const u8 {
    var folder = file.parent_folder;
    while (folder.parent_folder) |parent| folder = parent;
    const root = folder.path;
    if (root.len == 0) return file.path;
    if (std.mem.startsWith(u8, file.path, root)) {
        var index = root.len;
        if (index < file.path.len and (file.path[index] == '/' or file.path[index] == '\\')) index += 1;
        return file.path[index..];
    }
    return file.path;
}

/// Port of `SearchAccessibilityProvider.getAriaLabel` for text results.
pub fn ariaLabel(allocator: Allocator, node: Node, model: *const SearchModel) ![]u8 {
    return switch (node) {
        .heading => |heading| try allocator.dupe(u8, heading.name()),
        .folder => |folder| blk: {
            const count = folder.recursiveMatchCount();
            if (folder.is_other) {
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{d} matches outside of the workspace, Search result",
                    .{count},
                );
            }
            break :blk try std.fmt.allocPrint(
                allocator,
                "{d} matches in folder root {s}, Search result",
                .{ count, folder.name },
            );
        },
        .file => |file| blk: {
            const path = relativePath(file);
            const dirname = std.fs.path.dirname(path) orelse "";
            break :blk try std.fmt.allocPrint(
                allocator,
                "{d} matches in file {s} of folder {s}, Search result",
                .{ file.count(), file.name, dirname },
            );
        },
        .match => |match| blk: {
            const match_string = match.getMatchString();
            const range = match.range();
            const text = match.text();
            const end = @min(text.len, range.endColumn + 150);
            const replace = model.isReplaceActive() and model.replaceString().len > 0;
            if (replace) {
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "'{s}' at column {d} replace {s} with {s}",
                    .{ text[0..end], range.startColumn, match_string, model.replaceString() },
                );
            }
            break :blk try std.fmt.allocPrint(
                allocator,
                "'{s}' at column {d} found {s}",
                .{ text[0..end], range.startColumn, match_string },
            );
        },
    };
}

/// Port of `MatchRenderer.getMatchTitle`.
pub fn matchTitle(allocator: Allocator, match: *const Match, show_line_numbers: bool) ![]u8 {
    const range = match.range();
    const extra_lines = if (range.endLineNumber > range.startLineNumber)
        range.endLineNumber - range.startLineNumber
    else
        0;
    if (show_line_numbers and extra_lines > 0) {
        return std.fmt.allocPrint(
            allocator,
            "From line {d} + {d} more lines",
            .{ range.startLineNumber, extra_lines },
        );
    }
    if (show_line_numbers) {
        return std.fmt.allocPrint(allocator, "From line {d} ", .{range.startLineNumber});
    }
    if (extra_lines > 0) {
        return std.fmt.allocPrint(allocator, "+ {d} more lines", .{extra_lines});
    }
    return allocator.dupe(u8, "");
}

/// Port of the badge title formatting used by folder and file renderers.
pub fn badgeTitle(allocator: Allocator, node: Node) ![]u8 {
    return switch (node) {
        .folder => |folder| blk: {
            const count = folder.recursiveMatchCount();
            if (count == 1) break :blk try allocator.dupe(u8, "1 file found");
            break :blk try std.fmt.allocPrint(allocator, "{d} files found", .{count});
        },
        .file => |file| blk: {
            const count = file.count();
            if (count == 1) break :blk try allocator.dupe(u8, "1 match found");
            break :blk try std.fmt.allocPrint(allocator, "{d} matches found", .{count});
        },
        else => allocator.dupe(u8, ""),
    };
}
