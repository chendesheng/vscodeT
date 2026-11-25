// Port of AbstractResourceEditorInput.getDescription in
// src/vs/workbench/common/editor/resourceEditorInput.ts. The terminal workspace
// supplies local filesystem paths in place of URI labels.
const std = @import("std");
const Workspace = @import("../../../platform/workspace/common/workspace.zig").Workspace;
const Verbosity = @import("../editor.zig").Verbosity;

pub fn getDescription(arena: std.mem.Allocator, path: []const u8, verbosity: Verbosity, workspace: *const Workspace) !?[]const u8 {
    const directory = std.fs.path.dirname(path) orelse return null;
    if (verbosity == .SHORT) return std.fs.path.basename(directory);
    var label = directory;
    if (verbosity == .MEDIUM) {
        if (workspace.getFolder(directory)) |folder| {
            label = directory[folder.resource.len..];
            while (label.len != 0 and std.fs.path.isSep(label[0])) label = label[1..];
            if (workspace.folders.items.len > 1) {
                const name = if (folder.name.len != 0) folder.name else std.fs.path.basename(folder.resource);
                label = if (label.len == 0) name else try std.fmt.allocPrint(arena, "{s} • {s}", .{ name, label });
            }
        }
    }
    if (std.fs.path.sep == '\\' and std.mem.indexOfScalar(u8, label, '/') != null) {
        const native = try arena.dupe(u8, label);
        std.mem.replaceScalar(u8, native, '/', std.fs.path.sep);
        return native;
    }
    return label;
}
