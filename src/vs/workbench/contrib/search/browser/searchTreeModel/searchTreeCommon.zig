// Port of the portable search result tree from
// `src/vs/workbench/contrib/search/browser/searchTreeModel/`.
//
// Terminal adaptation:
// - resources are canonical path strings instead of URIs;
// - the notebook/AI node variants are omitted because those providers are not
//   ported;
// - the node implementations live in this one module so the pointer cycle
//   between file matches and line matches stays simple. The upstream-shaped
//   `match.zig`, `fileMatch.zig`, `folderMatch.zig`, `textSearchHeading.zig`
//   and `searchResult.zig` modules re-export the corresponding type.

const std = @import("std");
const Allocator = std.mem.Allocator;
const search = @import("../../../../services/search/common/search.zig");
pub const TextModel = @import("../../../../../editor/common/model/textModel.zig").TextModel;
const TextQuery = search.TextQuery;
const TextSearchMatch = search.TextSearchMatch;
const SearchRange = search.SearchRange;
const ReplacePattern = @import("../../../../services/search/common/replace.zig").ReplacePattern;
const Emitter = @import("../../../../../base/common/event.zig").Emitter;
const Range = @import("../../../../../editor/common/core/range.zig").Range;
const time_compat = @import("../../../../../base/common/timeCompat.zig");

pub const SEARCH_RESULT_PREFIX = "SEARCH_RESULT_";
pub const TEXT_SEARCH_HEADING_PREFIX = "TEXT_SEARCH_HEADING_";
pub const FOLDER_MATCH_PREFIX = "FOLDER_MATCH_";
pub const FILE_MATCH_PREFIX = "FILE_MATCH_";
pub const MATCH_PREFIX = "MATCH_";
pub const PLAIN_TEXT_SEARCH_RESULT_ID = "plainTextSearch";

pub const ChangeEvent = struct {
    elements: []const *FileMatch,
    added: bool = false,
    removed: bool = false,
    clearing_all: bool = false,
    force_update_model: bool = false,
};

pub const Node = union(enum) {
    heading: *TextSearchHeading,
    folder: *FolderMatch,
    file: *FileMatch,
    match: *Match,

    pub fn id(self: Node) []const u8 {
        return switch (self) {
            .heading => |value| value.id,
            .folder => |value| value.id,
            .file => |value| value.id,
            .match => |value| value.id,
        };
    }
};

fn emit(emitter: *Emitter(ChangeEvent), event: ChangeEvent) void {
    emitter.fire(event) catch {};
}

fn listenChange(emitter: *Emitter(ChangeEvent), ctx: anytype, callback: fn (ChangeEvent, @TypeOf(ctx)) anyerror!void) !void {
    try emitter.event(ctx, callback);
}

// ---------------------------------------------------------------------------
// Match
// ---------------------------------------------------------------------------

pub const Match = struct {
    allocator: Allocator,
    parent_file: *FileMatch,
    id: []u8,
    full_preview_lines: [][]u8,
    full_preview_range: SearchRange,
    preview_range: SearchRange,
    document_range: Range,

    pub fn create(
        allocator: Allocator,
        file: *FileMatch,
        preview_text: []const u8,
        preview_range: SearchRange,
        source_range: SearchRange,
    ) !*Match {
        var lines = std.array_list.Managed([]u8).init(allocator);
        errdefer {
            for (lines.items) |line| allocator.free(line);
            lines.deinit();
        }
        var iterator = std.mem.splitScalar(u8, preview_text, '\n');
        while (iterator.next()) |line| {
            try lines.append(try allocator.dupe(u8, line));
        }

        const document_range = Range.init(
            source_range.start_line_number + 1,
            source_range.start_column + 1,
            source_range.end_line_number + 1,
            source_range.end_column + 1,
        );
        const match = try allocator.create(Match);
        errdefer allocator.destroy(match);

        const id = try std.fmt.allocPrint(
            allocator,
            "{s}{s}>[{d},{d} -> {d},{d}]{s}",
            .{
                MATCH_PREFIX,
                file.path,
                document_range.startLineNumber,
                document_range.startColumn,
                document_range.endLineNumber,
                document_range.endColumn,
                textOfLine(lines.items, preview_range.start_line_number, preview_range.start_column, preview_range.end_column),
            },
        );
        errdefer allocator.free(id);

        match.* = .{
            .allocator = allocator,
            .parent_file = file,
            .id = id,
            .full_preview_lines = try lines.toOwnedSlice(),
            .full_preview_range = source_range,
            .preview_range = preview_range,
            .document_range = document_range,
        };
        return match;
    }

    pub fn deinit(self: *Match) void {
        for (self.full_preview_lines) |line| self.allocator.free(line);
        self.allocator.free(self.full_preview_lines);
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }

    pub fn parent(self: *Match) *FileMatch {
        return self.parent_file;
    }

    pub fn text(self: *const Match) []const u8 {
        if (self.full_preview_lines.len == 0) return "";
        return self.full_preview_lines[0];
    }

    pub fn range(self: *const Match) Range {
        return self.document_range;
    }

    pub const Preview = struct {
        before: []const u8,
        full_before: []const u8,
        before_truncated: bool = false,
        inside: []const u8,
        after: []const u8,
    };

    pub fn preview(self: *const Match) Preview {
        if (self.full_preview_lines.len == 0) {
            return .{ .before = "", .full_before = "", .inside = "", .after = "" };
        }
        const line_index = @min(self.preview_range.start_line_number, self.full_preview_lines.len - 1);
        const line = self.full_preview_lines[line_index];
        const start = @min(self.preview_range.start_column, line.len);
        const end = @min(self.preview_range.end_column, line.len);
        const full_before = line[0..start];
        // MatchImpl.preview uses lcut(fullBefore, 26, '…'). Keep the
        // marker separate so the borrowed preview retains its byte offsets.
        const trimmed = std.mem.trimStart(u8, full_before, " \t\r\n");
        var cut: usize = 0;
        var remaining = std.unicode.calcUtf16LeLen(trimmed) catch trimmed.len;
        var previous_word = false;
        for (trimmed, 0..) |byte, index| {
            if (remaining < 26) break;
            const word = std.ascii.isAlphanumeric(byte) or byte == '_';
            if (previous_word != word) cut = index;
            previous_word = word;
            if (byte & 0xc0 != 0x80) remaining -|= if (byte >= 0xf0) 2 else 1;
        }
        const before = std.mem.trimStart(u8, trimmed[cut..], " \t\r\n");
        return .{
            .before = before,
            .full_before = full_before,
            .before_truncated = cut != 0,
            .inside = line[start..end],
            .after = line[end..],
        };
    }

    pub fn getMatchString(self: *const Match) []const u8 {
        return self.preview().inside;
    }

    pub fn fullMatchText(self: *const Match, include_surrounding: bool) ![]u8 {
        if (self.full_preview_lines.len == 0) return try self.allocator.dupe(u8, "");
        if (!include_surrounding) {
            const start_index = @min(self.preview_range.start_line_number, self.full_preview_lines.len - 1);
            const end_index = @min(self.preview_range.end_line_number, self.full_preview_lines.len - 1);
            const start_column = if (self.preview_range.start_column == self.full_preview_range.start_column)
                self.full_preview_range.start_column
            else
                self.preview_range.start_column;
            const end_column = if (self.preview_range.end_column == self.full_preview_range.end_column)
                self.full_preview_range.end_column
            else
                self.preview_range.end_column;
            var out = std.array_list.Managed(u8).init(self.allocator);
            errdefer out.deinit();
            var line_index = start_index;
            while (line_index <= end_index) : (line_index += 1) {
                if (line_index > start_index) try out.append('\n');
                const line = self.full_preview_lines[line_index];
                const start = if (line_index == start_index) @min(start_column, line.len) else 0;
                const end = if (line_index == end_index) @min(end_column, line.len) else line.len;
                if (end >= start) try out.appendSlice(line[start..end]);
            }
            return try out.toOwnedSlice();
        }
        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();
        for (self.full_preview_lines, 0..) |line, index| {
            if (index > 0) try out.append('\n');
            try out.appendSlice(line);
        }
        return try out.toOwnedSlice();
    }

    pub fn rangeInPreview(self: *const Match) SearchRange {
        return .{
            .start_line_number = self.preview_range.start_line_number,
            .start_column = self.preview_range.start_column + 1,
            .end_line_number = self.preview_range.end_line_number,
            .end_column = self.preview_range.end_column + 1,
        };
    }

    pub fn fullPreviewLines(self: *const Match, allocator: Allocator) ![][]const u8 {
        const start = @min(self.preview_range.start_line_number, self.full_preview_lines.len);
        const end = @min(self.preview_range.end_line_number + 1, self.full_preview_lines.len);
        const result = try allocator.alloc([]const u8, end - start);
        for (self.full_preview_lines[start..end], 0..) |line, index| result[index] = line;
        return result;
    }

    pub fn replaceString(
        self: *const Match,
        allocator: Allocator,
        pattern: *const ReplacePattern,
        preserve_case: bool,
    ) ![]u8 {
        const full = try self.fullMatchText(false);
        defer self.allocator.free(full);
        if (try pattern.getReplaceString(allocator, full, preserve_case)) |value| return value;
        return try allocator.dupe(u8, pattern.pattern());
    }

    pub fn isSelected(self: *const Match) bool {
        return self.parent_file.selected == self;
    }
};

fn textOfLine(lines: []const []u8, line_index: usize, start: usize, end: usize) []const u8 {
    if (lines.len == 0) return "";
    const line = lines[@min(line_index, lines.len - 1)];
    const from = @min(start, line.len);
    const to = @min(end, line.len);
    if (to < from) return "";
    return line[from..to];
}

// ---------------------------------------------------------------------------
// FileMatch
// ---------------------------------------------------------------------------

pub const FileMatch = @import("fileMatch.zig").FileMatch;

// ---------------------------------------------------------------------------
// FolderMatch
// ---------------------------------------------------------------------------

pub const FolderMatch = struct {
    allocator: Allocator,
    path: []u8,
    name: []u8,
    id: []u8,
    index: usize,
    parent_folder: ?*FolderMatch,
    heading: *TextSearchHeading,
    query: *const TextQuery,
    folders: std.array_list.Managed(*FolderMatch),
    files: std.array_list.Managed(*FileMatch),
    folder_map: std.StringHashMap(*FolderMatch),
    file_map: std.StringHashMap(*FileMatch),
    is_workspace_root: bool,
    is_other: bool,
    on_change: Emitter(ChangeEvent),
    on_dispose: Emitter(void),

    pub fn create(
        allocator: Allocator,
        path: []const u8,
        index: usize,
        parent_folder: ?*FolderMatch,
        heading: *TextSearchHeading,
        query: *const TextQuery,
        is_workspace_root: bool,
        is_other: bool,
    ) !*FolderMatch {
        const self = try allocator.create(FolderMatch);
        errdefer allocator.destroy(self);
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        const name = try allocator.dupe(u8, if (is_other) "Other files" else std.fs.path.basename(path));
        errdefer allocator.free(name);
        const id = try std.fmt.allocPrint(allocator, "{s}{s}", .{ FOLDER_MATCH_PREFIX, if (is_other) "otherFiles" else path });
        errdefer allocator.free(id);
        self.* = .{
            .allocator = allocator,
            .path = path_copy,
            .name = name,
            .id = id,
            .index = index,
            .parent_folder = parent_folder,
            .heading = heading,
            .query = query,
            .folders = std.array_list.Managed(*FolderMatch).init(allocator),
            .files = std.array_list.Managed(*FileMatch).init(allocator),
            .folder_map = std.StringHashMap(*FolderMatch).init(allocator),
            .file_map = std.StringHashMap(*FileMatch).init(allocator),
            .is_workspace_root = is_workspace_root,
            .is_other = is_other,
            .on_change = Emitter(ChangeEvent).init(allocator),
            .on_dispose = Emitter(void).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *FolderMatch) void {
        self.on_dispose.fire({}) catch {};
        var owned_files = self.file_map.valueIterator();
        while (owned_files.next()) |file| file.*.deinit();
        for (self.folders.items) |folder| folder.deinit();
        self.files.deinit();
        self.folders.deinit();
        self.file_map.deinit();
        self.folder_map.deinit();
        self.on_change.deinit();
        self.on_dispose.deinit();
        self.allocator.free(self.path);
        self.allocator.free(self.name);
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }

    pub fn parent(self: *FolderMatch) ?*FolderMatch {
        return self.parent_folder;
    }

    pub fn getFolderMatch(self: *FolderMatch, path: []const u8) ?*FolderMatch {
        if (self.folder_map.get(path)) |folder| return folder;
        var best: ?*FolderMatch = null;
        for (self.folders.items) |folder| {
            if (pathIsInside(folder.path, path)) {
                if (best == null or folder.path.len > best.?.path.len) best = folder;
            }
        }
        return best;
    }

    pub fn getDownstreamFileMatch(self: *FolderMatch, path: []const u8) ?*FileMatch {
        if (self.file_map.get(path)) |file| return file;
        for (self.folders.items) |folder| {
            if (folder.getDownstreamFileMatch(path)) |file| return file;
        }
        return null;
    }

    pub fn addFileMatch(
        self: *FolderMatch,
        path: []const u8,
        results: []const TextSearchMatch,
        contexts: []const search.TextSearchContext,
        silent: bool,
    ) !void {
        if (self.getDownstreamFileMatch(path)) |existing| {
            try existing.addRawMatches(results);
            try existing.addContexts(contexts);
            if (!silent) existing.notify(true, false) else _ = try existing.parent_folder.syncFileVisibility(existing);
            return;
        }
        if (self.is_workspace_root and pathIsInside(self.path, path) and !std.mem.eql(u8, self.path, path)) {
            if (std.fs.path.dirname(path)) |dir| {
                if (!std.mem.eql(u8, dir, self.path) and pathIsInside(self.path, dir)) {
                    var current = self;
                    var relative = dir[self.path.len..];
                    while (relative.len > 0 and isSeparator(relative[0])) relative = relative[1..];
                    var built = try self.allocator.dupe(u8, self.path);
                    defer self.allocator.free(built);
                    var segments = std.mem.tokenizeAny(u8, relative, "/\\");
                    while (segments.next()) |segment| {
                        if (segment.len == 0) continue;
                        const next_path = try joinSearchPath(self.allocator, built, segment);
                        self.allocator.free(built);
                        built = next_path;
                        current = try current.createIntermediate(built);
                    }
                    return current.addFileMatch(path, results, contexts, silent);
                }
            }
        }
        if (!self.is_workspace_root and !self.is_other) {
            // Intermediate folders only add files under themselves.
            if (!pathIsInside(self.path, path)) return;
        }
        const file = try FileMatch.create(self.allocator, path, self);
        errdefer file.deinit();
        try file.createMatches(results);
        if (file.model == null) try file.addContexts(contexts);
        try self.addFile(file);
        if (!silent and file.count() > 0) file.notify(true, false);
    }

    pub fn createIntermediate(self: *FolderMatch, path: []const u8) !*FolderMatch {
        if (self.folder_map.get(path)) |folder| return folder;
        const folder = try FolderMatch.create(
            self.allocator,
            path,
            self.index,
            self,
            self.heading,
            self.query,
            false,
            false,
        );
        try self.addFolder(folder);
        return folder;
    }

    pub fn addFile(self: *FolderMatch, file: *FileMatch) !void {
        try self.files.ensureUnusedCapacity(1);
        try self.file_map.put(file.path, file);
        if (file.count() != 0) self.files.appendAssumeCapacity(file);
    }

    pub fn addFolder(self: *FolderMatch, folder: *FolderMatch) !void {
        try self.folders.append(folder);
        try self.folder_map.put(folder.path, folder);
    }

    pub fn removeFile(self: *FolderMatch, file: *FileMatch) void {
        for (self.files.items, 0..) |candidate, index| {
            if (candidate == file) {
                _ = self.files.orderedRemove(index);
                _ = self.file_map.remove(file.path);
                const elements = [1]*FileMatch{file};
                emit(&self.on_change, .{ .elements = elements[0..], .removed = true });
                file.deinit();
                return;
            }
        }
        for (self.folders.items) |folder| {
            if (pathIsInside(folder.path, file.path)) {
                folder.removeFile(file);
                return;
            }
        }
    }

    pub fn removeFolder(self: *FolderMatch, folder: *FolderMatch) void {
        for (self.folders.items, 0..) |candidate, index| {
            if (candidate == folder) {
                _ = self.folders.orderedRemove(index);
                _ = self.folder_map.remove(folder.path);
                const files = folder.allDownstreamFiles(self.allocator) catch null;
                if (files) |value| {
                    emit(&self.on_change, .{ .elements = value, .removed = true });
                    self.allocator.free(value);
                } else {
                    emit(&self.on_change, .{ .elements = &.{}, .removed = true });
                }
                folder.deinit();
                return;
            }
        }
    }

    // Upstream keeps undisposed files available to their model listeners
    // when their final match is removed.
    fn syncFileVisibility(self: *FolderMatch, file: *FileMatch) !ChangeEvent {
        const visible = std.mem.indexOfScalar(*FileMatch, self.files.items, file);
        const empty = file.count() == 0;
        if (empty) {
            if (visible) |index| _ = self.files.orderedRemove(index);
        } else if (visible == null) {
            try self.files.append(file);
        }
        return .{ .elements = &.{}, .added = !empty and visible == null, .removed = empty and visible != null };
    }

    pub fn onModelMatchesUpdated(self: *FolderMatch, file: *FileMatch) void {
        var event = self.syncFileVisibility(file) catch return;
        const elements = [1]*FileMatch{file};
        event.elements = &elements;
        event.force_update_model = true;
        emit(&self.on_change, event);
        self.heading.notifyChange(event);
    }

    pub fn onFileChanged(self: *FolderMatch, file: *FileMatch, removed: bool) void {
        var event = self.syncFileVisibility(file) catch return;
        const elements = [1]*FileMatch{file};
        event.elements = &elements;
        event.removed = file.count() == 0 or removed;
        emit(&self.on_change, event);
        self.heading.notifyChange(event);
    }

    pub fn matches(self: *FolderMatch, allocator: Allocator) ![]Node {
        var result = std.array_list.Managed(Node).init(allocator);
        errdefer result.deinit();
        for (self.files.items) |file| try result.append(.{ .file = file });
        for (self.folders.items) |folder| try result.append(.{ .folder = folder });
        return try result.toOwnedSlice();
    }

    pub fn allDownstreamFiles(self: *FolderMatch, allocator: Allocator) ![]*FileMatch {
        var result = std.array_list.Managed(*FileMatch).init(allocator);
        errdefer result.deinit();
        try result.appendSlice(self.files.items);
        for (self.folders.items) |folder| {
            const children = try folder.allDownstreamFiles(allocator);
            defer allocator.free(children);
            try result.appendSlice(children);
        }
        return try result.toOwnedSlice();
    }

    pub fn recursiveFileCount(self: *FolderMatch) usize {
        return self.files.items.len + blk: {
            var count: usize = 0;
            for (self.folders.items) |folder| count += folder.recursiveFileCount();
            break :blk count;
        };
    }

    pub fn recursiveMatchCount(self: *FolderMatch) usize {
        var count: usize = 0;
        for (self.files.items) |file| count += file.count();
        for (self.folders.items) |folder| count += folder.recursiveMatchCount();
        return count;
    }

    pub fn clear(self: *FolderMatch) void {
        var owned_files = self.file_map.valueIterator();
        while (owned_files.next()) |file| file.*.deinit();
        for (self.folders.items) |folder| folder.deinit();
        self.files.clearRetainingCapacity();
        self.folders.clearRetainingCapacity();
        self.file_map.clearRetainingCapacity();
        self.folder_map.clearRetainingCapacity();
    }

    pub fn listen(self: *FolderMatch, ctx: anytype, callback: fn (ChangeEvent, @TypeOf(ctx)) anyerror!void) !void {
        try listenChange(&self.on_change, ctx, callback);
    }
};

// ---------------------------------------------------------------------------
// TextSearchHeading
// ---------------------------------------------------------------------------

pub const TextSearchHeading = struct {
    allocator: Allocator,
    id: []u8,
    parent_result: *SearchResult,
    query: ?*const TextQuery = null,
    folders: std.array_list.Managed(*FolderMatch),
    other: ?*FolderMatch = null,
    cached_complete: bool = false,
    on_change: Emitter(ChangeEvent),

    pub fn create(allocator: Allocator, parent: *SearchResult) !*TextSearchHeading {
        const self = try allocator.create(TextSearchHeading);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .id = try std.fmt.allocPrint(allocator, "{s}{s}", .{ TEXT_SEARCH_HEADING_PREFIX, PLAIN_TEXT_SEARCH_RESULT_ID }),
            .parent_result = parent,
            .folders = std.array_list.Managed(*FolderMatch).init(allocator),
            .on_change = Emitter(ChangeEvent).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *TextSearchHeading) void {
        self.setQuery(null);
        self.folders.deinit();
        self.on_change.deinit();
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }

    pub fn name(self: *const TextSearchHeading) []const u8 {
        _ = self;
        return "Text Results";
    }

    pub fn setQuery(self: *TextSearchHeading, query: ?*const TextQuery) void {
        if (self.folders.items.len > 0 or self.other != null) {
            for (self.folders.items) |folder| folder.deinit();
            self.folders.clearRetainingCapacity();
            if (self.other) |folder| folder.deinit();
            self.other = null;
        }
        self.query = query;
        if (query) |value| {
            for (value.folder_paths, 0..) |path, index| {
                const folder = FolderMatch.create(
                    self.allocator,
                    path,
                    index,
                    null,
                    self,
                    value,
                    true,
                    false,
                ) catch continue;
                self.folders.append(folder) catch {};
            }
            self.other = FolderMatch.create(
                self.allocator,
                "",
                self.folders.items.len,
                null,
                self,
                value,
                false,
                true,
            ) catch null;
        }
    }

    pub fn getFolderMatch(self: *TextSearchHeading, path: []const u8) ?*FolderMatch {
        var best: ?*FolderMatch = null;
        for (self.folders.items) |folder| {
            if (pathIsInside(folder.path, path)) {
                if (best == null or folder.path.len > best.?.path.len) best = folder;
            }
        }
        return best orelse self.other;
    }

    pub fn add(self: *TextSearchHeading, files: []const search.SearchFileResult, silent: bool) !void {
        for (files) |file| {
            const folder = self.getFolderMatch(file.resource) orelse continue;
            try folder.addFileMatch(file.resource, file.results, file.contexts, silent);
        }
        self.notifyChange(.{ .elements = &.{}, .added = true });
    }

    pub fn folderMatches(self: *TextSearchHeading, allocator: Allocator) ![]*FolderMatch {
        var result = std.array_list.Managed(*FolderMatch).init(allocator);
        errdefer result.deinit();
        for (self.folders.items) |folder| {
            if (folder.recursiveMatchCount() > 0) try result.append(folder);
        }
        if (self.other) |folder| {
            if (folder.recursiveMatchCount() > 0) try result.append(folder);
        }
        return try result.toOwnedSlice();
    }

    pub fn matches(self: *TextSearchHeading, allocator: Allocator) ![]*FileMatch {
        var result = std.array_list.Managed(*FileMatch).init(allocator);
        errdefer result.deinit();
        for (self.folders.items) |folder| {
            const files = try folder.allDownstreamFiles(allocator);
            defer allocator.free(files);
            try result.appendSlice(files);
        }
        if (self.other) |folder| {
            const files = try folder.allDownstreamFiles(allocator);
            defer allocator.free(files);
            try result.appendSlice(files);
        }
        return try result.toOwnedSlice();
    }

    pub fn count(self: *TextSearchHeading) usize {
        var total: usize = 0;
        for (self.folders.items) |folder| total += folder.recursiveMatchCount();
        if (self.other) |folder| total += folder.recursiveMatchCount();
        return total;
    }

    pub fn fileCount(self: *TextSearchHeading) usize {
        var total: usize = 0;
        for (self.folders.items) |folder| total += folder.recursiveFileCount();
        if (self.other) |folder| total += folder.recursiveFileCount();
        return total;
    }

    pub fn isEmpty(self: *TextSearchHeading) bool {
        return self.count() == 0;
    }

    pub fn clear(self: *TextSearchHeading) void {
        for (self.folders.items) |folder| folder.clear();
        if (self.other) |folder| folder.clear();
        self.cached_complete = false;
        self.notifyChange(.{ .elements = &.{}, .removed = true, .clearing_all = true });
    }

    pub fn removeFolder(self: *TextSearchHeading, folder: *FolderMatch) void {
        if (self.other) |other| {
            if (other == folder) {
                other.deinit();
                self.other = null;
                return;
            }
        }
        for (self.folders.items, 0..) |candidate, index| {
            if (candidate == folder) {
                _ = self.folders.orderedRemove(index);
                folder.deinit();
                return;
            }
        }
    }

    pub fn notifyChange(self: *TextSearchHeading, event: ChangeEvent) void {
        emit(&self.on_change, event);
        self.parent_result.forwardChange(event);
    }

    pub fn listen(self: *TextSearchHeading, ctx: anytype, callback: fn (ChangeEvent, @TypeOf(ctx)) anyerror!void) !void {
        try listenChange(&self.on_change, ctx, callback);
    }
};

// ---------------------------------------------------------------------------
// SearchResult
// ---------------------------------------------------------------------------

pub const SearchResult = struct {
    allocator: Allocator,
    id: []u8,
    heading: *TextSearchHeading,
    query: ?*const TextQuery = null,
    model_host: ?ModelHost = null,
    on_change: Emitter(ChangeEvent),

    pub const ModelHost = struct {
        context: *anyopaque,
        get: *const fn (*anyopaque, []const u8) ?*TextModel,
        queue: *@import("../../../../../base/common/windowDispatch.zig").Queue,
    };

    pub fn create(allocator: Allocator) !*SearchResult {
        const self = try allocator.create(SearchResult);
        errdefer allocator.destroy(self);
        const id = try std.fmt.allocPrint(allocator, "{s}{d}", .{ SEARCH_RESULT_PREFIX, time_compat.milliTimestamp() });
        errdefer allocator.free(id);
        self.* = .{
            .allocator = allocator,
            .id = id,
            .heading = try TextSearchHeading.create(allocator, self),
            .on_change = Emitter(ChangeEvent).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *SearchResult) void {
        self.heading.deinit();
        self.on_change.deinit();
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }

    pub fn setQuery(self: *SearchResult, query: ?*const TextQuery) void {
        self.query = query;
        self.heading.setQuery(query);
    }

    pub fn add(self: *SearchResult, files: []const search.SearchFileResult, silent: bool) !void {
        try self.heading.add(files, silent);
    }

    pub fn clear(self: *SearchResult) void {
        self.heading.clear();
    }

    pub fn onModelAdded(self: *SearchResult, path: []const u8, model: *TextModel) !void {
        const folder = self.heading.getFolderMatch(path) orelse return;
        if (folder.getDownstreamFileMatch(path)) |file| try file.bindModel(model);
    }

    pub fn matches(self: *SearchResult, allocator: Allocator) ![]*FileMatch {
        return try self.heading.matches(allocator);
    }

    pub fn folderMatches(self: *SearchResult, allocator: Allocator) ![]*FolderMatch {
        return try self.heading.folderMatches(allocator);
    }

    pub fn count(self: *SearchResult) usize {
        return self.heading.count();
    }

    pub fn fileCount(self: *SearchResult) usize {
        return self.heading.fileCount();
    }

    pub fn isEmpty(self: *SearchResult) bool {
        return self.heading.isEmpty();
    }

    pub fn forwardChange(self: *SearchResult, event: ChangeEvent) void {
        emit(&self.on_change, event);
    }

    pub fn listen(self: *SearchResult, ctx: anytype, callback: fn (ChangeEvent, @TypeOf(ctx)) anyerror!void) !void {
        try listenChange(&self.on_change, ctx, callback);
    }

    pub fn removeFile(self: *SearchResult, file: *FileMatch) void {
        _ = self;
        file.parent_folder.removeFile(file);
    }

    pub fn removeMatch(self: *SearchResult, match: *Match) void {
        _ = self;
        match.parent_file.remove(match);
    }

    /// Port of upstream `ISearchResult.batchRemove` for text results. Elements
    /// are expected to be distinct; callers remove ancestors before children.
    pub fn batchRemove(self: *SearchResult, elements: []const Node) void {
        for (elements) |element| {
            switch (element) {
                .heading => self.clear(),
                .folder => |folder| {
                    if (folder.parent_folder) |parent| {
                        parent.removeFolder(folder);
                    } else {
                        self.heading.removeFolder(folder);
                    }
                },
                .file => |file| file.parent_folder.removeFile(file),
                .match => |match| match.parent_file.remove(match),
            }
        }
    }
};

/// Node-level helpers used by the view and action ports.
pub fn nodeParent(node: Node) ?Node {
    return switch (node) {
        .heading => null,
        .folder => |folder| if (folder.parent_folder) |parent|
            Node{ .folder = parent }
        else
            Node{ .heading = folder.heading },
        .file => |file| Node{ .folder = file.parent_folder },
        .match => |match| Node{ .file = match.parent_file },
    };
}

pub fn nodeEql(a: Node, b: Node) bool {
    return switch (a) {
        .heading => |value| b == .heading and b.heading == value,
        .folder => |value| b == .folder and b.folder == value,
        .file => |value| b == .file and b.file == value,
        .match => |value| b == .match and b.match == value,
    };
}

pub fn isSearchTreeMatch(node: Node) bool {
    return node == .match;
}

pub fn isSearchTreeFileMatch(node: Node) bool {
    return node == .file;
}

pub fn isSearchTreeFolderMatch(node: Node) bool {
    return node == .folder;
}

pub fn isTextSearchHeading(node: Node) bool {
    return node == .heading;
}

fn isSeparator(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

fn pathIsInside(root: []const u8, path: []const u8) bool {
    if (root.len == 0) return true;
    if (std.mem.eql(u8, root, path)) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (isSeparator(root[root.len - 1])) return true;
    return path.len > root.len and isSeparator(path[root.len]);
}

/// Joins a relative folder segment while preserving the separator style of the
/// base path. Search results arrive either as `/`-rooted test paths or native
/// Windows paths; mixing separators breaks the prefix checks above.
fn joinSearchPath(allocator: Allocator, base: []const u8, segment: []const u8) ![]u8 {
    const separator: u8 = if (std.mem.indexOfScalar(u8, base, '\\') != null and std.mem.indexOfScalar(u8, base, '/') == null) '\\' else '/';
    const needs_separator = base.len > 0 and !isSeparator(base[base.len - 1]);
    const result = try allocator.alloc(u8, base.len + @intFromBool(needs_separator) + segment.len);
    @memcpy(result[0..base.len], base);
    var index = base.len;
    if (needs_separator) {
        result[index] = separator;
        index += 1;
    }
    @memcpy(result[index..][0..segment.len], segment);
    return result;
}

test "SearchResult: adds files, matches and folder hierarchy" {
    const allocator = std.testing.allocator;
    var query = try TextQuery.init(allocator, "foo", &.{"/root"}, "", "", &.{});
    defer query.deinit();
    const result = try SearchResult.create(allocator);
    defer result.deinit();
    result.setQuery(&query);

    const ranges = [_]SearchRange{SearchRange.init(1, 0, 1, 3)};
    const raw = try TextSearchMatch.init(allocator, "foo bar", &ranges, .{ .match_lines = 1, .chars_per_line = 1000 });
    var files = [_]search.SearchFileResult{.{
        .allocator = allocator,
        .resource = try allocator.dupe(u8, "/root/src/a.zig"),
        .results = try allocator.alloc(TextSearchMatch, 1),
    }};
    files[0].results[0] = raw;
    defer files[0].deinit();

    try result.add(&files, false);
    try std.testing.expectEqual(@as(usize, 1), result.count());
    try std.testing.expectEqual(@as(usize, 1), result.fileCount());
}

test "SearchResult: nested folders and events" {
    const allocator = std.testing.allocator;
    var query = try TextQuery.init(allocator, "foo", &.{"/root"}, "", "", &.{});
    defer query.deinit();
    const result = try SearchResult.create(allocator);
    defer result.deinit();
    result.setQuery(&query);

    const ranges = [_]SearchRange{SearchRange.init(0, 0, 0, 3)};
    const raw = try TextSearchMatch.init(allocator, "foo", &ranges, .{ .match_lines = 1, .chars_per_line = 1000 });
    var file_result = search.SearchFileResult{
        .allocator = allocator,
        .resource = try allocator.dupe(u8, "/root/src/deep/a.zig"),
        .results = try allocator.alloc(TextSearchMatch, 1),
    };
    file_result.results[0] = raw;
    defer file_result.deinit();

    var added = false;
    try result.listen(&added, struct {
        fn onChange(event: ChangeEvent, value: *bool) !void {
            if (event.added or event.elements.len > 0) value.* = true;
        }
    }.onChange);
    try result.add(&.{file_result}, false);
    try std.testing.expect(added);
    const folders = try result.folderMatches(allocator);
    defer allocator.free(folders);
    try std.testing.expectEqual(@as(usize, 1), folders.len);
    try std.testing.expectEqualStrings("root", folders[0].name);
    try std.testing.expectEqual(@as(usize, 1), folders[0].folders.items.len);
    const files = try result.matches(allocator);
    defer allocator.free(files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
}
