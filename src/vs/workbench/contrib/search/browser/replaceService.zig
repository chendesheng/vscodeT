// Port of the portable replacement flow in
// `src/vs/workbench/contrib/search/browser/replaceService.ts`.
//
// The browser service applies resource text edits through the bulk-edit and
// text-file services. The terminal service hands one edit batch per file to an
// `IEditorHost`, which applies it to the open editor (and saves) or writes a
// closed file directly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Range = @import("../../../../editor/common/core/range.zig").Range;
const FileMatch = @import("searchTreeModel/searchTreeCommon.zig").FileMatch;
const Match = @import("searchTreeModel/searchTreeCommon.zig").Match;
const ReplacePattern = @import("../../../services/search/common/replace.zig").ReplacePattern;

pub const Edit = struct {
    range: Range,
    text: []const u8,
};

pub const IEditorHost = struct {
    context: *anyopaque,
    apply_edits: *const fn (context: *anyopaque, path: []const u8, edits: []const Edit) anyerror!void,
    save_file: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
};

pub const IReplaceService = struct {
    context: *anyopaque,
    replace_files: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        files: []*FileMatch,
        pattern: *const ReplacePattern,
        preserve_case: bool,
    ) anyerror!void,
};

pub const ReplaceService = struct {
    allocator: Allocator,
    host: IEditorHost,

    pub fn init(allocator: Allocator, host: IEditorHost) ReplaceService {
        return .{ .allocator = allocator, .host = host };
    }

    pub fn interface(self: *ReplaceService) IReplaceService {
        return .{ .context = self, .replace_files = replaceFilesCallback };
    }

    /// Replaces one selected line match. The file's other matches stay in
    /// the result tree; this mirrors upstream `FileMatch.replace(match)`.
    pub fn replaceMatches(
        self: *ReplaceService,
        allocator: Allocator,
        matches: []*Match,
        pattern: *const ReplacePattern,
        preserve_case: bool,
    ) !void {
        for (matches) |match| {
            const text = match.replaceString(allocator, pattern, preserve_case) catch continue;
            defer allocator.free(text);
            const edits = [_]Edit{.{ .range = match.range(), .text = text }};
            try self.host.apply_edits(self.host.context, match.parent_file.path, &edits);
            try self.host.save_file(self.host.context, match.parent_file.path);
        }
    }

    pub fn replaceFiles(
        self: *ReplaceService,
        allocator: Allocator,
        files: []*FileMatch,
        pattern: *const ReplacePattern,
        preserve_case: bool,
    ) !void {
        for (files) |file| {
            if (file.count() == 0) continue;
            var edits = std.array_list.Managed(OwnedEdit).init(allocator);
            defer {
                for (edits.items) |edit| allocator.free(edit.text);
                edits.deinit();
            }
            for (file.matches()) |match| {
                const text = match.replaceString(allocator, pattern, preserve_case) catch continue;
                try edits.append(.{ .range = match.range(), .text = text });
            }
            if (edits.items.len == 0) continue;

            const views = try allocator.alloc(Edit, edits.items.len);
            defer allocator.free(views);
            for (edits.items, 0..) |edit, index| {
                views[index] = .{ .range = edit.range, .text = edit.text };
            }
            try self.host.apply_edits(self.host.context, file.path, views);
            try self.host.save_file(self.host.context, file.path);
        }
    }
};

const OwnedEdit = struct {
    range: Range,
    text: []u8,
};

fn replaceFilesCallback(
    context: *anyopaque,
    allocator: Allocator,
    files: []*FileMatch,
    pattern: *const ReplacePattern,
    preserve_case: bool,
) anyerror!void {
    const self: *ReplaceService = @ptrCast(@alignCast(context));
    return self.replaceFiles(allocator, files, pattern, preserve_case);
}
