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
const SaveCompletion = @import("../../../services/workingCopy/common/workingCopy.zig").SaveCompletion;
const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const Window = @import("../../../../base/common/windowDispatch.zig");

pub const Edit = struct {
    range: Range,
    text: []const u8,
};

pub const IEditorHost = struct {
    context: *anyopaque,
    window: ?*Window.Queue = null,
    model_version: ?*const fn (*anyopaque, []const u8) ?u32 = null,
    apply_edits: *const fn (context: *anyopaque, path: []const u8, edits: []const Edit) anyerror!void,
    save_file: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
    request_save_file: ?*const fn (*anyopaque, []const u8, SaveCompletion) anyerror!void = null,
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

    const Batch = struct {
        const File = struct { path: []const u8, edits: []const Edit, version: ?u32 = null };
        arena: std.heap.ArenaAllocator,
        callback: ?SaveCompletion,
        remaining: usize = 1,
        result: anyerror!bool = true,
        host: IEditorHost = undefined,
        files: []const File = &.{},
        edit_future: ?std.Io.Future(anyerror!void) = null,
        edit_completion: Window.Task = .{},

        fn completed(context: *anyopaque, result: anyerror!bool) void {
            const self: *Batch = @ptrCast(@alignCast(context));
            if (result) |saved| {
                if (!saved and (self.result catch false)) self.result = false;
            } else |err| self.result = err;
            self.release();
        }

        fn release(self: *Batch) void {
            self.remaining -= 1;
            if (self.remaining != 0) return;
            const allocator = self.arena.child_allocator;
            const callback = self.callback;
            const result = self.result;
            self.arena.deinit();
            allocator.destroy(self);
            if (callback) |value| value.complete(value.context, result);
        }

        fn detach(context: *anyopaque) void {
            const self: *Batch = @ptrCast(@alignCast(context));
            self.callback = null;
            if (self.edit_future) |*future| {
                future.cancel(self.host.window.?.io) catch {};
                self.edit_future = null;
                self.edit_completion.schedule(null);
                self.release();
            }
        }

        fn start(self: *Batch, host: IEditorHost, files: []const File) !?Disposable {
            self.host = host;
            self.files = files;
            const handle: Disposable = .{ .context = self, .disposeFn = detach };
            if (host.window) |window| {
                if (window.scheduler != null) {
                    self.edit_completion = .{ .queue = window, .context = self, .run = editCompleted, .progress = true };
                    self.edit_future = try window.io.concurrent(editAsync, .{self});
                    return handle;
                }
            }
            self.applyAll() catch |err| {
                self.result = err;
            };
            const pending = self.remaining > 1;
            self.release();
            return if (pending) handle else null;
        }

        fn editAsync(self: *Batch) anyerror!void {
            defer self.edit_completion.post();
            try self.applyAll();
        }

        fn editCompleted(context: *anyopaque, _: i64, _: bool) bool {
            const self: *Batch = @ptrCast(@alignCast(context));
            self.edit_future.?.await(self.host.window.?.io) catch |err| {
                self.result = err;
            };
            self.edit_future = null;
            self.release();
            return true;
        }

        fn applyAll(self: *Batch) !void {
            const host = self.host;
            var applied: usize = 0;
            for (self.files) |file| {
                if (host.window) |window| try window.io.checkCancel();
                if (host.model_version) |version| {
                    if (version(host.context, file.path) != file.version) {
                        self.result = error.StaleSearchResult;
                        break;
                    }
                }
                host.apply_edits(host.context, file.path, file.edits) catch |err| {
                    self.result = err;
                    break;
                };
                applied += 1;
            }
            // Upstream applies the resource edits first, then waits for all
            // affected working-copy saves. Save participants may edit other
            // files, so do not start them in the middle of applying edits.
            for (self.files[0..applied]) |file| {
                self.remaining += 1;
                const completion: SaveCompletion = .{ .context = self, .complete = completed };
                if (host.request_save_file) |request| {
                    request(host.context, file.path, completion) catch |err| completed(self, err);
                } else {
                    host.save_file(host.context, file.path) catch |err| {
                        completed(self, err);
                        continue;
                    };
                    completed(self, true);
                }
            }
        }
    };

    fn modelVersion(self: *ReplaceService, path: []const u8) ?u32 {
        const version = self.host.model_version orelse return null;
        return version(self.host.context, path);
    }

    fn createBatch(self: *ReplaceService, completion: SaveCompletion) !*Batch {
        const batch = try self.allocator.create(Batch);
        batch.* = .{ .arena = .init(self.allocator), .callback = completion };
        return batch;
    }

    pub fn requestMatches(self: *ReplaceService, matches: []const *Match, pattern: *const ReplacePattern, preserve_case: bool, completion: SaveCompletion) !?Disposable {
        const batch = try self.createBatch(completion);
        errdefer {
            batch.arena.deinit();
            self.allocator.destroy(batch);
        }
        const a = batch.arena.allocator();
        const Group = struct { path: []const u8, edits: std.ArrayList(Edit) = .empty };
        var groups: std.ArrayList(Group) = .empty;
        for (matches) |match| {
            const text = match.replaceString(a, pattern, preserve_case) catch continue;
            var found: ?*Group = null;
            for (groups.items) |*group| if (std.mem.eql(u8, group.path, match.parent_file.path)) {
                found = group;
                break;
            };
            if (found == null) {
                try groups.append(a, .{ .path = try a.dupe(u8, match.parent_file.path) });
                found = &groups.items[groups.items.len - 1];
            }
            try found.?.edits.append(a, .{ .range = match.range(), .text = text });
        }
        var files: std.ArrayList(Batch.File) = .empty;
        for (groups.items) |group| try files.append(a, .{ .path = group.path, .edits = group.edits.items, .version = self.modelVersion(group.path) });
        return batch.start(self.host, files.items);
    }

    pub fn requestFiles(self: *ReplaceService, matches: []const *FileMatch, pattern: *const ReplacePattern, preserve_case: bool, completion: SaveCompletion) !?Disposable {
        const batch = try self.createBatch(completion);
        errdefer {
            batch.arena.deinit();
            self.allocator.destroy(batch);
        }
        const a = batch.arena.allocator();
        var files: std.ArrayList(Batch.File) = .empty;
        for (matches) |file| {
            var edits: std.ArrayList(Edit) = .empty;
            for (file.matches()) |match| {
                const text = match.replaceString(a, pattern, preserve_case) catch continue;
                try edits.append(a, .{ .range = match.range(), .text = text });
            }
            if (edits.items.len == 0) continue;
            try files.append(a, .{ .path = try a.dupe(u8, file.path), .edits = edits.items, .version = self.modelVersion(file.path) });
        }
        return batch.start(self.host, files.items);
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
    window: ?*Window.Queue = null,

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
        if (self.window) |window| {
            return Window.workerCall(window.io, applyClosedFileEdits, .{ self.allocator, Window.backingIo(window.io), path, edits });
        }
        return applyClosedFileEdits(self.allocator, self.io, path, edits);
    }

    fn applyClosedFileEdits(allocator: Allocator, io: std.Io, path: []const u8, edits: []const Edit) !void {
        const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(content);

        var starts = std.array_list.Managed(usize).init(allocator);
        defer starts.deinit();
        var bom_len: usize = 0;
        if (content.len >= 3 and content[0] == 0xef and content[1] == 0xbb and content[2] == 0xbf) bom_len = 3;
        try starts.append(bom_len);
        for (content, 0..) |ch, index| {
            if (ch == '\n' and index + 1 <= content.len) try starts.append(index + 1);
        }

        const Resolved = struct { start: usize, end: usize, text: []const u8 };
        var resolved = std.array_list.Managed(Resolved).init(allocator);
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

        var buffer = std.array_list.Managed(u8).init(allocator);
        defer buffer.deinit();
        try buffer.appendSlice(content);
        for (resolved.items) |edit| {
            if (edit.end < edit.start or edit.end > buffer.items.len) continue;
            try buffer.replaceRange(edit.start, edit.end - edit.start, edit.text);
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buffer.items });
    }

    pub fn requestSaveFile(self: *NativeEditorHost, path: []const u8, completion: SaveCompletion) !void {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!tab.isDiff() and pathsEqual(tab.editor.path, path)) {
                    return tab.editor.requestSave(completion);
                }
            }
        }
        completion.complete(completion.context, true);
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
