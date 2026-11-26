// Port of src/vs/editor/browser/widget/diffEditor/utils/editorGutter.ts.
// The terminal frame is a cell grid rather than retained positioned DOM
// item nodes. The item provider supplies ordered layout bounds; render
// visits each intersecting item once and clips its layout to the viewport.
const LineRange = @import("../../../../common/core/ranges/lineRange.zig").LineRange;

pub const IGutterItemProvider = struct {
    context: *const anyopaque,
    item_count: usize,
    bounds: *const fn (*const anyopaque, usize) LineRange,
};

pub const EditorGutter = struct {
    provider: IGutterItemProvider,
    viewport: LineRange,
    index: usize,

    pub const ItemView = struct {
        index: usize,
        bounds: LineRange,
        visible: LineRange,
    };

    pub fn render(provider: IGutterItemProvider, viewport: LineRange) EditorGutter {
        var low: usize = 0;
        var high = provider.item_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (provider.bounds(provider.context, mid).endLineNumberExclusive <= viewport.startLineNumber) {
                low = mid + 1;
            } else high = mid;
        }
        return .{ .provider = provider, .viewport = viewport, .index = low };
    }

    pub fn next(self: *EditorGutter) ?ItemView {
        while (self.index < self.provider.item_count) {
            const index = self.index;
            self.index += 1;
            const bounds = self.provider.bounds(self.provider.context, index);
            if (bounds.startLineNumber >= self.viewport.endLineNumberExclusive) return null;
            const visible = bounds.intersect(self.viewport) orelse continue;
            if (visible.isEmpty()) continue;
            return .{ .index = index, .bounds = bounds, .visible = visible };
        }
        return null;
    }
};

test "gutterFeature: EditorGutter clips ordered item views without visiting offscreen items" {
    const testing = @import("std").testing;
    const Provider = struct {
        ranges: []const LineRange,

        fn bounds(context: *const anyopaque, index: usize) LineRange {
            const self: *const @This() = @ptrCast(@alignCast(context));
            return self.ranges[index];
        }
    };
    const provider: Provider = .{ .ranges = &.{ .init(0, 3), .init(5, 9), .init(10, 13), .init(20, 22) } };
    var gutter = EditorGutter.render(.{ .context = &provider, .item_count = provider.ranges.len, .bounds = Provider.bounds }, .init(7, 12));
    const first = gutter.next().?;
    try testing.expectEqual(@as(usize, 1), first.index);
    try testing.expectEqual(LineRange.init(7, 9), first.visible);
    try testing.expectEqual(LineRange.init(5, 9), first.bounds);
    const second = gutter.next().?;
    try testing.expectEqual(@as(usize, 2), second.index);
    try testing.expectEqual(LineRange.init(10, 12), second.visible);
    try testing.expect(gutter.next() == null);
}
