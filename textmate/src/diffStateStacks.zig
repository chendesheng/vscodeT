// Port of `../vscode-textmate/src/diffStateStacks.ts`
// (microsoft/vscode-textmate v9.3.2).
const std = @import("std");
const grammar = @import("grammar/grammar.zig");
const Allocator = std.mem.Allocator;

pub const StackDiff = struct {
    pops: usize,
    new_frames: []grammar.StateStackFrame,

    pub fn deinit(self: *StackDiff, allocator: Allocator) void {
        for (self.new_frames) |frame| {
            for (frame.name_scopes_list) |scope_frame| allocator.free(scope_frame.scope_names);
            for (frame.content_name_scopes_list) |scope_frame| allocator.free(scope_frame.scope_names);
            allocator.free(frame.name_scopes_list);
            allocator.free(frame.content_name_scopes_list);
        }
        allocator.free(self.new_frames);
    }
};

pub fn diffStateStacksRefEq(
    allocator: Allocator,
    first: *grammar.StateStackImpl,
    second: *grammar.StateStackImpl,
) !StackDiff {
    var pops: usize = 0;
    var new_frames: std.ArrayList(grammar.StateStackFrame) = .empty;
    errdefer new_frames.deinit(allocator);

    var cur_first: ?*grammar.StateStackImpl = first;
    var cur_second: ?*grammar.StateStackImpl = second;

    while (cur_first != cur_second) {
        if (cur_first != null and (cur_second == null or cur_first.?.depth >= cur_second.?.depth)) {
            pops += 1;
            cur_first = cur_first.?.parent;
        } else {
            try new_frames.append(allocator, try cur_second.?.toStateStackFrame(allocator));
            cur_second = cur_second.?.parent;
        }
    }

    std.mem.reverse(grammar.StateStackFrame, new_frames.items);
    return .{ .pops = pops, .new_frames = try new_frames.toOwnedSlice(allocator) };
}

pub fn applyStateStackDiff(
    allocator: Allocator,
    stack: ?*grammar.StateStackImpl,
    diff: StackDiff,
) !?*grammar.StateStackImpl {
    var current = stack;
    var i: usize = 0;
    while (i < diff.pops) : (i += 1) {
        current = current.?.parent;
    }
    for (diff.new_frames) |frame| {
        current = try grammar.StateStackImpl.pushFrame(allocator, current, frame);
    }
    return current;
}
