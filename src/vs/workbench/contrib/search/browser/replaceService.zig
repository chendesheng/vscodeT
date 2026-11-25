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
        files: []const *FileMatch,
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
        matches: []const *Match,
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
        files: []const *FileMatch,
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
    files: []const *FileMatch,
    pattern: *const ReplacePattern,
    preserve_case: bool,
) anyerror!void {
    const self: *ReplaceService = @ptrCast(@alignCast(context));
    return self.replaceFiles(allocator, files, pattern, preserve_case);
}

const builtin = @import("builtin");
const Tab = @import("../../../browser/parts/editor/editorPane.zig").Tab;
const GroupView = @import("../../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("../../../browser/parts/editor/editorPart.zig").EditorPart(GroupView);
const TextEdit = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").TextEdit;

/// Native bulk-edit and text-file adapter for ReplaceService. Open resources
/// receive one editor edit batch; closed resources use the native file I/O
/// path until the full bulk-edit service is ported.
pub const NativeEditorHost = struct {
    allocator: Allocator,
    io: std.Io,
    part: *EditorPart,

    pub fn applyEdits(self: *NativeEditorHost, path: []const u8, edits: []const Edit) anyerror!void {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!pathsEqual(tab.editor.path, path)) continue;
                const converted = try self.allocator.alloc(TextEdit, edits.len);
                defer self.allocator.free(converted);
                for (edits, 0..) |edit, index| {
                    converted[index] = .{ .range = edit.range, .text = edit.text };
                }
                try tab.editor.applyTextEdits(converted, &.{});
                return;
            }
        }
        return self.applyClosedFileEdits(path, edits);
    }

    fn applyClosedFileEdits(self: *NativeEditorHost, path: []const u8, edits: []const Edit) !void {
        const content = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(64 * 1024 * 1024));
        defer self.allocator.free(content);

        var starts = std.array_list.Managed(usize).init(self.allocator);
        defer starts.deinit();
        var bom_len: usize = 0;
        if (content.len >= 3 and content[0] == 0xef and content[1] == 0xbb and content[2] == 0xbf) bom_len = 3;
        try starts.append(bom_len);
        for (content, 0..) |ch, index| {
            if (ch == '\n' and index + 1 <= content.len) try starts.append(index + 1);
        }

        const Resolved = struct { start: usize, end: usize, text: []const u8 };
        var resolved = std.array_list.Managed(Resolved).init(self.allocator);
        defer resolved.deinit();
        for (edits) |edit| {
            const start = offsetAt(starts.items, edit.range.startLineNumber, edit.range.startColumn);
            const end = offsetAt(starts.items, edit.range.endLineNumber, edit.range.endColumn);
            try resolved.append(.{ .start = @min(start, content.len), .end = @min(end, content.len), .text = edit.text });
        }
        std.sort.heap(Resolved, resolved.items, {}, struct {
            fn lessThan(_: void, a: Resolved, b: Resolved) bool {
                return a.start > b.start;
            }
        }.lessThan);

        var buffer = std.array_list.Managed(u8).init(self.allocator);
        defer buffer.deinit();
        try buffer.appendSlice(content);
        for (resolved.items) |edit| {
            if (edit.end < edit.start or edit.end > buffer.items.len) continue;
            try buffer.replaceRange(edit.start, edit.end - edit.start, edit.text);
        }
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = buffer.items });
    }

    pub fn saveFile(self: *NativeEditorHost, path: []const u8) anyerror!void {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!tab.isDiff() and pathsEqual(tab.editor.path, path)) {
                    try tab.editor.save();
                    return;
                }
            }
        }
    }

    fn offsetAt(starts: []const usize, line: usize, column: usize) usize {
        if (starts.len == 0) return 0;
        const index = @min(line -| 1, starts.len - 1);
        return starts[index] + (column -| 1);
    }

    /// Compares resource paths across the CLI/test boundary. Windows tests and
    /// callers can mix `/` and `\`, and Windows paths are case-insensitive.
    fn pathsEqual(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |left, right| {
            if (left == right) continue;
            const separators = (left == '/' or left == '\\') and (right == '/' or right == '\\');
            if (separators) continue;
            if (builtin.os.tag == .windows and std.ascii.toLower(left) == std.ascii.toLower(right)) continue;
            return false;
        }
        return true;
    }
};
