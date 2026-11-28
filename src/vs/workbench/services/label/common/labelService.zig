// Port of local file labels from `src/vs/workbench/services/label/common/labelService.ts`.
// This subset uses the native URI/path boundary and current workspace folder
// lookup. Custom extension-provided and remote resource formatters are not
// yet ported. No filesystem operations are needed to format a relative label.
const std = @import("std");
const label = @import("../../../../platform/label/common/label.zig");
const std_uri = @import("../../../../base/common/stdUri.zig");
const WorkspaceContextService = @import("../../workspaces/common/workspaceContextService.zig").WorkspaceContextService;

pub const LabelService = struct {
    workspace: *WorkspaceContextService,

    pub fn interface(self: *LabelService) label.ILabelService {
        return .{ .context = self, .get_uri_label = getUriLabel };
    }

    fn getUriLabel(context: *anyopaque, allocator: std.mem.Allocator, resource: std.Uri, options: label.LabelOptions) ![]u8 {
        const self: *LabelService = @ptrCast(@alignCast(context));
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const path = try std_uri.fsPath(resource, a);
        if (options.relative and std.mem.eql(u8, resource.scheme, "file")) {
            if (self.workspace.getWorkspaceFolder(path)) |folder| {
                const separators = if (@import("builtin").os.tag == .windows) "/\\" else "/";
                const root = std.mem.trimEnd(u8, folder.resource, separators);
                const relative = std.mem.trimStart(u8, path[root.len..], separators);
                if (!options.noPrefix and self.workspace.getWorkspace().folders.items.len > 1) {
                    return if (relative.len == 0)
                        allocator.dupe(u8, folder.name)
                    else
                        std.fmt.allocPrint(allocator, "{s} • {s}", .{ folder.name, relative });
                }
                return allocator.dupe(u8, relative);
            }
        }
        return allocator.dupe(u8, path);
    }
};
