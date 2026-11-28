// Port of the sequential IPageIterator contract in `src/vs/base/common/paging.ts`.
// The terminal's paged list resolves the next visible page through its owner
// task; the cursor owns ordering and completion independently of transport.
const std = @import("std");

pub const PageIterator = struct {
    page_size: usize,
    total: usize = 0,
    resolved: usize = 0,
    page: usize = 0,

    pub fn accept(self: *PageIterator, page: usize, count: usize, total: usize) !void {
        if (page != self.page + 1) return error.UnexpectedPage;
        self.page = page;
        self.total = total;
        self.resolved += count;
        if (count == 0) self.total = self.resolved;
    }

    pub fn hasNextPage(self: PageIterator) bool {
        return self.page == 0 or self.resolved < self.total;
    }

    pub fn nextPage(self: PageIterator) ?usize {
        return if (self.hasNextPage()) self.page + 1 else null;
    }
};

test "PageIterator: sequential pages stop at total or empty page" {
    var iterator: PageIterator = .{ .page_size = 50 };
    try std.testing.expectEqual(@as(?usize, 1), iterator.nextPage());
    try iterator.accept(1, 50, 115);
    try std.testing.expectEqual(@as(?usize, 2), iterator.nextPage());
    try std.testing.expectError(error.UnexpectedPage, iterator.accept(3, 15, 115));
    try iterator.accept(2, 50, 115);
    try iterator.accept(3, 15, 115);
    try std.testing.expectEqual(@as(?usize, null), iterator.nextPage());
    iterator = .{ .page_size = 50 };
    try iterator.accept(1, 0, 100);
    try std.testing.expect(!iterator.hasNextPage());
}
