// Port of the RELATIVE_FILEPATH case from
// `src/vs/editor/contrib/snippet/test/browser/snippetVariables.test.ts`.
const std = @import("std");
const variables = @import("../../browser/snippetVariables.zig");
const parser = @import("../../browser/snippetParser.zig");
const labels = @import("../../../../../workbench/services/label/common/labelService.zig");
const workspace_mod = @import("../../../../../workbench/services/workspaces/common/workspaceContextService.zig");

test "snippet variables: RELATIVE_FILEPATH is a workspace label, not a cwd lookup" {
    const a = std.testing.allocator;
    const workspace = try workspace_mod.WorkspaceContextService.initEmpty(a, "test");
    defer workspace.deinit();
    var service = labels.LabelService{ .workspace = workspace };
    const root = if (@import("builtin").os.tag == .windows) "C:\\foo" else "/foo";
    const path = try std.fs.path.join(a, &.{ root, "files", "text.txt" });
    defer a.free(path);
    const snippet = try parser.TextmateSnippet.init(a);
    defer snippet.deinit();
    const variable = try snippet.newVariable("RELATIVE_FILEPATH");
    var resolver = variables.ModelBasedVariableResolver{ .model_path = path, .label_service = service.interface() };
    const absolute = (try resolver.resolve(a, variable)).?;
    defer a.free(absolute);
    try std.testing.expectEqualStrings(path, absolute);
    try workspace.addFolder(root);
    const result = (try resolver.resolve(a, variable)).?;
    defer a.free(result);
    const expected = try std.fs.path.join(a, &.{ "files", "text.txt" });
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, result);
    const sibling = try std.fmt.allocPrint(a, "{s}-other{s}text.txt", .{ root, std.fs.path.sep_str });
    defer a.free(sibling);
    resolver.model_path = sibling;
    const outside = (try resolver.resolve(a, variable)).?;
    defer a.free(outside);
    try std.testing.expectEqualStrings(sibling, outside);
}
