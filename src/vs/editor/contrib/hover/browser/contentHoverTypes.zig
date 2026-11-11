// Port of `src/vs/editor/contrib/hover/browser/contentHoverTypes.ts`.
//
// Ownership: the terminal port stores the part values in a slice it owns, so a
// result can outlive the `HoverOperation` that produced it. `filter` consumes
// the previous result and returns the filtered one; callers must drop the old
// value without calling `deinit` again.
const std = @import("std");
const Allocator = std.mem.Allocator;

const hoverTypes = @import("./hoverTypes.zig");
const HoverAnchor = hoverTypes.HoverAnchor;
const IHoverPart = hoverTypes.IHoverPart;
const ContentHoverComputerOptions = @import("./contentHoverComputer.zig").ContentHoverComputerOptions;

pub const ContentHoverResult = struct {
    allocator: Allocator,
    hover_parts: []IHoverPart,
    is_complete: bool,
    options: ContentHoverComputerOptions,

    pub fn init(
        allocator: Allocator,
        hover_parts: []const IHoverPart,
        is_complete: bool,
        options: ContentHoverComputerOptions,
    ) !ContentHoverResult {
        return .{
            .allocator = allocator,
            .hover_parts = try allocator.dupe(IHoverPart, hover_parts),
            .is_complete = is_complete,
            .options = options,
        };
    }

    pub fn deinit(self: *ContentHoverResult) void {
        if (self.hover_parts.len > 0) self.allocator.free(self.hover_parts);
        self.hover_parts = &.{};
    }

    pub fn isEmpty(self: *const ContentHoverResult) bool {
        return self.hover_parts.len == 0;
    }

    /// Keeps only the parts that are still valid for the new anchor. Returns
    /// `self` unchanged when nothing was filtered out.
    pub fn filter(self: *ContentHoverResult, anchor: *const HoverAnchor) !ContentHoverResult {
        var kept: usize = 0;
        for (self.hover_parts) |*part| {
            if (part.isValidForHoverAnchor(anchor)) kept += 1;
        }
        if (kept == self.hover_parts.len) {
            return .{
                .allocator = self.allocator,
                .hover_parts = self.hover_parts,
                .is_complete = self.is_complete,
                .options = self.options,
            };
        }

        const filtered = try self.allocator.alloc(IHoverPart, kept);
        var index: usize = 0;
        for (self.hover_parts) |*part| {
            if (!part.isValidForHoverAnchor(anchor)) continue;
            filtered[index] = part.*;
            index += 1;
        }
        self.allocator.free(self.hover_parts);
        self.hover_parts = &.{};
        return .{
            .allocator = self.allocator,
            .hover_parts = filtered,
            .is_complete = self.is_complete,
            .options = self.options,
        };
    }
};

test "contentHoverResult: filters invalid parts" {
    const testing = std.testing;
    const Range = @import("../../../common/core/range.zig").Range;

    const AlwaysValid = struct {
        fn check(_: *const IHoverPart, _: *const HoverAnchor) bool {
            return true;
        }
    };

    const NeverValid = struct {
        fn check(_: *const IHoverPart, _: *const HoverAnchor) bool {
            return false;
        }
    };

    const valid_part = IHoverPart{
        .owner = @ptrFromInt(1),
        .range = Range.init(1, 1, 1, 2),
        .is_valid_for_hover_anchor = AlwaysValid.check,
    };
    const invalid_part = IHoverPart{
        .owner = @ptrFromInt(2),
        .range = Range.init(1, 2, 1, 3),
        .is_valid_for_hover_anchor = NeverValid.check,
    };

    const anchor = HoverAnchor{ .range = hoverTypes.HoverRangeAnchor.init(1, Range.init(1, 1, 1, 2)) };
    var result = try ContentHoverResult.init(
        testing.allocator,
        &[_]IHoverPart{ valid_part, invalid_part },
        true,
        .{ .anchor = anchor },
    );
    defer result.deinit();

    const filtered = try result.filter(&anchor);
    defer {
        var value = filtered;
        value.deinit();
    }
    try testing.expectEqual(@as(usize, 1), filtered.hover_parts.len);
    try testing.expectEqual(valid_part.range.startColumn, filtered.hover_parts[0].range.startColumn);
}
