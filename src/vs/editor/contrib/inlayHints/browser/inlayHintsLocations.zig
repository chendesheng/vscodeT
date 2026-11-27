// Port of `src/vs/editor/contrib/inlayHints/browser/inlayHintsLocations.ts`.
// Actual URI opening and command execution remain workbench service operations.
const std = @import("std");
const languages = @import("../../../common/languages.zig");
const std_uri = @import("../../../../base/common/stdUri.zig");
const opener_mod = @import("../../../../platform/opener/common/opener.zig");
const EditorMod = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig");
pub fn openPart(a: std.mem.Allocator, part: languages.InlayHintLabelPart, opener: opener_mod.IOpenerService, commands: languages.CommandHost) !void {
    if (part.location) |location| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        const uri = try std.Uri.parse(location.uri);
        opener.open(.{ .scheme = uri.scheme, .authority = try std_uri.authority(uri, scratch), .path = try std_uri.path(uri, scratch), .query = try std_uri.query(uri, scratch), .fragment = try std_uri.fragment(uri, scratch) }, location.range.getStartPosition());
    } else if (part.command) |command| try commands.execute(commands.context, command);
}
pub fn applyTextEdits(editor: *EditorMod.Editor, edits: []const languages.TextEdit) !void {
    if (edits.len == 0 or editor.isReadOnly()) return;
    const converted = try editor.allocator.alloc(EditorMod.TextEdit, edits.len);
    defer editor.allocator.free(converted);
    for (edits, converted) |edit, *target| target.* = .{ .range = edit.range, .text = edit.text };
    try editor.applyTextEdits(converted, &.{});
}
