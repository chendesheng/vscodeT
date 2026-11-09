// Port of `src/vs/editor/contrib/hover/browser/contentHoverTypes.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const hoverTypes = @import("./hoverTypes.zig");
const HoverAnchor = hoverTypes.HoverAnchor;
const IHoverPart = hoverTypes.IHoverPart;

pub const ContentHoverResult = struct {
    hover_parts: []const IHoverPart,
    is_complete: bool,

    pub fn filter(self: ContentHoverResult, allocator: Allocator, anchor: *const HoverAnchor) !ContentHoverResult {
        var filtered = ArrayList(IHoverPart).init(allocator);
        errdefer filtered.deinit();

        for (self.hover_parts) |part| {
            if (part.isValidForHoverAnchor(anchor)) try filtered.append(part);
        }

        if (filtered.items.len == self.hover_parts.len) {
            filtered.deinit();
            return self;
        }

        return .{
            .hover_parts = try filtered.toOwnedSlice(),
            .is_complete = self.is_complete,
        };
    }
};

test "contentHoverResult: filters invalid parts" {
    const testing = std.testing;
    const Range = @import("../../../common/core/range.zig").Range;

    const AlwaysValid = struct {
        fn check(_: *const anyopaque, _: *const HoverAnchor) bool {
            return true;
        }
    };

    var valid_part = IHoverPart{
        .owner = @ptrFromInt(1),
        .range = Range.init(1, 1, 1, 2),
        .is_valid_for_hover_anchor = AlwaysValid.check,
    };
    var invalid_part = IHoverPart{
        .owner = @ptrFromInt(2),
        .range = Range.init(1, 2, 1, 3),
        .is_valid_for_hover_anchor = struct {
            fn check(_: *const anyopaque, _: *const HoverAnchor) bool {
                return false;
            }
        }.check,
    };

    const anchor = HoverAnchor{ .range = hoverTypes.HoverRangeAnchor.init(1, Range.init(1, 1, 1, 2)) };
    const result = ContentHoverResult{
        .hover_parts = &[_]IHoverPart{ valid_part, invalid_part },
        .is_complete = true,
    };
    const filtered = try result.filter(testing.allocator, &anchor);
    defer if (filtered.hover_parts.ptr != result.hover_parts.ptr) testing.allocator.free(filtered.hover_parts);
    try testing.expectEqual(@as(usize, 1), filtered.hover_parts.len);
    try testing.expectEqual(valid_part.range.startColumn, filtered.hover_parts[0].range.startColumn);

    _ = &valid_part;
    _ = &invalid_part;
}
