// Port of `src/vs/editor/contrib/codeAction/browser/codeActionMenu.ts`.
const std = @import("std");
const types = @import("../common/types.zig");
const Kind = @import("../../../../base/common/hierarchicalKind.zig").HierarchicalKind;
const list = @import("../../../../platform/actionWidget/browser/actionList.zig");
const Groups = [_]struct { kind: Kind, title: []const u8 }{
    .{ .kind = types.CodeActionKind.QuickFix, .title = "Quick Fix" },
    .{ .kind = types.CodeActionKind.RefactorExtract, .title = "Extract" },
    .{ .kind = types.CodeActionKind.RefactorInline, .title = "Inline" },
    .{ .kind = types.CodeActionKind.RefactorRewrite, .title = "Rewrite" },
    .{ .kind = types.CodeActionKind.RefactorMove, .title = "Move" },
    .{ .kind = types.CodeActionKind.SurroundWith, .title = "Surround With" },
    .{ .kind = types.CodeActionKind.Source, .title = "Source Action" },
    .{ .kind = Kind.Empty, .title = "More Actions..." },
};

pub fn toMenuItems(a: std.mem.Allocator, actions: []const types.CodeActionItem, headers: bool) ![]list.IActionListItem {
    var result: std.ArrayList(list.IActionListItem) = .empty;
    errdefer result.deinit(a);
    if (!headers) {
        for (actions, 0..) |item, index| try result.append(a, row(item, index, false));
    } else {
        var groups: [Groups.len]std.ArrayList(usize) = @splat(.empty);
        defer for (&groups) |*items| items.deinit(a);
        for (actions, 0..) |item, index| {
            const kind = if (item.action.kind) |value| Kind.init(value) else Kind.None;
            for (Groups, 0..) |group, group_index| {
                if (group.kind.contains(kind)) {
                    try groups[group_index].append(a, index);
                    break;
                }
            }
        }
        for (Groups, &groups) |group, *items| {
            if (items.items.len == 0) continue;
            try result.append(a, .{ .kind = .Header, .label = group.title });
            for (items.items) |index| try result.append(a, row(actions[index], index, true));
        }
    }
    return result.toOwnedSlice(a);
}

fn row(item: types.CodeActionItem, index: usize, headers: bool) list.IActionListItem {
    return .{ .kind = .Action, .item = index, .label = if (!headers) item.action.disabled orelse item.action.title else item.action.title, .disabled = item.action.disabled != null, .can_preview = if (item.action.edit) |edit| edit.edits.len > 0 else false };
}
